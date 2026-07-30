import Foundation
import Network
import AVFoundation

// MARK: - iOS Client Connection Manager & TLV Serializer

@MainActor
public final class ClientConnectionManager: ObservableObject {
    @Published public var isConnected: Bool = false
    @Published public var isAuthenticated: Bool = false
    @Published public var authFailed: Bool = false
    @Published public var hostIP: String = "Quintessa.local"
    @Published public var port: UInt16 = 8088
    @Published public var remoteFiles: [String] = []
    
    public let displayLayer = AVSampleBufferDisplayLayer()
    private var decoder: iPhoneClientVideoDecoder?
    private var connection: NWConnection?
    
    public init() {
        let videoDecoder = iPhoneClientVideoDecoder(displayLayer: displayLayer)
        self.decoder = videoDecoder
        videoDecoder.onRequestIDRKeyframe = { [weak self] in
            Task { @MainActor in
                self?.requestIDRKeyframe()
            }
        }
    }
    
    public func connect(host: String, port: UInt16) {
        self.hostIP = host
        self.port = port
        self.isAuthenticated = false
        self.authFailed = false
        
        let targetHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(targetHost), port: NWEndpoint.Port(rawValue: port)!)
        
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        
        // TLV Protocol Framer Setup
        let framerOption = NWProtocolFramer.Options(definition: TailRemoteFramer.definition)
        parameters.defaultProtocolStack.applicationProtocols.insert(framerOption, at: 0)
        
        let nwConnection = NWConnection(to: endpoint, using: parameters)
        self.connection = nwConnection
        
        nwConnection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    print("✅ iPhone: Connected to Mac Host at \(targetHost):\(port). Awaiting PIN entry...")
                    self?.isConnected = true
                    self?.receiveNextTLV()
                case .failed(let error):
                    print("❌ iPhone: Connection failed to \(targetHost):\(port) - Error: \(error)")
                    self?.isConnected = false
                    self?.isAuthenticated = false
                case .cancelled:
                    self?.isConnected = false
                    self?.isAuthenticated = false
                default:
                    break
                }
            }
        }
        
        nwConnection.start(queue: .global(qos: .userInteractive))
    }
    
    public func disconnect() {
        connection?.cancel()
        connection = nil
        isConnected = false
        isAuthenticated = false
        authFailed = false
    }
    
    // MARK: - Handshake PIN Authenticator (TLV Type 0x01)
    
    public func authenticate(pin: String) {
        guard let pinData = pin.data(using: .utf8) else { return }
        sendTLV(type: .authPIN, payload: pinData)
    }
    
    // MARK: - Recursive TLV Receiver Loop
    
    private func receiveNextTLV() {
        guard let connection = connection else { return }
        
        connection.receiveMessage { [weak self] content, context, isComplete, error in
            guard let self = self, error == nil, let content = content else { return }
            
            if let framerMessage = context?.protocolMetadata(definition: TailRemoteFramer.definition) as? NWProtocolFramer.Message,
               let msgTypeRaw = framerMessage.messageType,
               let msgType = TailRemoteMessageType(rawValue: msgTypeRaw) {
                
                Task { @MainActor in
                    self.processInboundTLV(type: msgType, payload: content)
                }
            }
            
            Task { @MainActor in
                self.receiveNextTLV()
            }
        }
    }
    
    private func processInboundTLV(type: TailRemoteMessageType, payload: Data) {
        switch type {
        case .authPIN:
            if payload.first == 0x01 {
                print("🔓 iPhone: Gatekeeper Authentication Succeeded!")
                self.isAuthenticated = true
                self.authFailed = false
                self.requestIDRKeyframe()
            } else {
                print("❌ iPhone: Gatekeeper Authentication Failed (Incorrect PIN).")
                self.isAuthenticated = false
                self.authFailed = true
            }
            
        case .videoFrame:
            guard payload.count >= 1 else { return }
            let subType = payload[0]
            let videoData = payload.subdata(in: 1..<payload.count)
            
            switch subType {
            case 0x01: // Format Description
                decoder?.handleFormatDescription(data: videoData)
            case 0x02: // Keyframe
                decoder?.handleVideoFrame(data: videoData, isKeyframe: true)
            case 0x03: // P-Frame
                decoder?.handleVideoFrame(data: videoData, isKeyframe: false)
            default:
                break
            }
            
        default:
            break
        }
    }
    
    // MARK: - Send Mouse & Keyboard Input (TLV Types 0x03 & 0x04)
    
    public func sendRelativeMove(dx: Float, dy: Float) {
        var payload = Data([0x01]) // Sub-type 0x01: Relative Move
        var dxBE = dx.bitPattern.bigEndian
        var dyBE = dy.bitPattern.bigEndian
        withUnsafeBytes(of: &dxBE) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &dyBE) { payload.append(contentsOf: $0) }
        
        sendTLV(type: .mouseInput, payload: payload)
    }
    
    public func sendAbsoluteMove(normalizedX: Float, normalizedY: Float) {
        var payload = Data([0x02]) // Sub-type 0x02: Absolute Move
        var xBE = normalizedX.bitPattern.bigEndian
        var yBE = normalizedY.bitPattern.bigEndian
        withUnsafeBytes(of: &xBE) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &yBE) { payload.append(contentsOf: $0) }
        
        sendTLV(type: .mouseInput, payload: payload)
    }
    
    public func sendMouseButton(button: MouseButtonType, state: MouseButtonState) {
        let payload = Data([0x03, button.rawValue, state.rawValue]) // Sub-type 0x03: Mouse Button
        sendTLV(type: .mouseInput, payload: payload)
    }
    
    public func sendScroll(scrollDx: Float, scrollDy: Float) {
        var payload = Data([0x04]) // Sub-type 0x04: Scroll Event
        var dxBE = scrollDx.bitPattern.bigEndian
        var dyBE = scrollDy.bitPattern.bigEndian
        withUnsafeBytes(of: &dxBE) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &dyBE) { payload.append(contentsOf: $0) }
        
        sendTLV(type: .mouseInput, payload: payload)
    }
    
    public func sendKeystroke(_ char: String) {
        guard let data = char.data(using: .utf8) else { return }
        sendTLV(type: .keyboardCommand, payload: data)
    }
    
    public func requestIDRKeyframe() {
        // Send empty request auth/control ping if needed
        sendTLV(type: .authPIN, payload: Data("PING".utf8))
    }
    
    // MARK: - Single Contiguous Data TLV Serializer
    
    private func sendTLV(type: TailRemoteMessageType, payload: Data) {
        guard let connection = connection else { return }
        
        let message = NWProtocolFramer.Message(type: type)
        let context = NWConnection.ContentContext(identifier: "ClientTLV", metadata: [message])
        
        payload.withUnsafeBytes { rawBuffer in
            let dispatchData = DispatchData(bytes: rawBuffer)
            connection.send(content: dispatchData, contentContext: context, isComplete: true, completion: .idempotent)
        }
    }
}
