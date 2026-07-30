import Foundation
import Network
import AVFoundation

// MARK: - iOS Client Connection Manager

@MainActor
public final class ClientConnectionManager: ObservableObject {
    @Published public var isConnected: Bool = false
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
        
        let targetHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(targetHost), port: NWEndpoint.Port(rawValue: port)!)
        
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        
        // Protocol Framer Setup
        let framerOption = NWProtocolFramer.Options(definition: TailRemoteFramer.definition)
        parameters.defaultProtocolStack.applicationProtocols.insert(framerOption, at: 0)
        
        let nwConnection = NWConnection(to: endpoint, using: parameters)
        self.connection = nwConnection
        
        nwConnection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    print("✅ iPhone: Connected to Mac Host at \(targetHost):\(port)")
                    self?.isConnected = true
                    self?.receiveNextPacket()
                    // Immediate Keyframe Handshake on Connection .ready
                    self?.requestIDRKeyframe()
                    print("⚡️ iPhone: Transmitted initial RequestIDR Keyframe handshake to Mac Host")
                case .failed(let error):
                    print("❌ iPhone: Connection failed to \(targetHost):\(port) - Error: \(error)")
                    self?.isConnected = false
                case .cancelled:
                    self?.isConnected = false
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
    }
    
    // MARK: - Packet Receiver Loop
    
    private func receiveNextPacket() {
        guard let connection = connection else { return }
        
        connection.receiveMessage { [weak self] content, context, isComplete, error in
            guard let self = self, error == nil, let content = content else { return }
            
            if let framerMessage = context?.protocolMetadata(definition: TailRemoteFramer.definition) as? NWProtocolFramer.Message,
               let channelID = framerMessage.channelID,
               let messageType = framerMessage.messageType {
                
                Task { @MainActor in
                    self.processInboundPacket(channelID: channelID, messageType: messageType, payload: content)
                }
            }
            
            Task { @MainActor in
                self.receiveNextPacket()
            }
        }
    }
    
    private func processInboundPacket(channelID: UInt8, messageType: UInt8, payload: Data) {
        guard let channel = TailRemoteChannel(rawValue: channelID),
              let msgType = TailRemoteMessageType(rawValue: messageType) else { return }
        
        switch channel {
        case .video:
            switch msgType {
            case .formatDescription:
                decoder?.handleFormatDescription(data: payload)
            case .keyframe:
                decoder?.handleVideoFrame(data: payload, isKeyframe: true)
            case .pFrame:
                decoder?.handleVideoFrame(data: payload, isKeyframe: false)
            default:
                break
            }
        case .fileTransfer:
            if msgType == .fileDirectoryListResp {
                if let fileList = try? JSONDecoder().decode([String].self, from: payload) {
                    self.remoteFiles = fileList
                }
            }
        default:
            break
        }
    }
    
    // MARK: - Send Input Events (Channel 1)
    
    public func sendRelativeMove(dx: Float, dy: Float) {
        var payload = Data()
        var dxBE = dx.bitPattern.bigEndian
        var dyBE = dy.bitPattern.bigEndian
        withUnsafeBytes(of: &dxBE) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &dyBE) { payload.append(contentsOf: $0) }
        
        sendPacket(channel: .input, messageType: .pointerMoveRelative, payload: payload)
    }
    
    public func sendAbsoluteMove(normalizedX: Float, normalizedY: Float) {
        var payload = Data()
        var xBE = normalizedX.bitPattern.bigEndian
        var yBE = normalizedY.bitPattern.bigEndian
        withUnsafeBytes(of: &xBE) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &yBE) { payload.append(contentsOf: $0) }
        
        sendPacket(channel: .input, messageType: .pointerMoveAbsolute, payload: payload)
    }
    
    public func sendMouseButton(button: MouseButtonType, state: MouseButtonState) {
        let payload = Data([button.rawValue, state.rawValue])
        sendPacket(channel: .input, messageType: .mouseButton, payload: payload)
    }
    
    public func sendScroll(scrollDx: Float, scrollDy: Float) {
        var payload = Data()
        var dxBE = scrollDx.bitPattern.bigEndian
        var dyBE = scrollDy.bitPattern.bigEndian
        withUnsafeBytes(of: &dxBE) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &dyBE) { payload.append(contentsOf: $0) }
        
        sendPacket(channel: .input, messageType: .scrollEvent, payload: payload)
    }
    
    public func sendKeystroke(_ char: String) {
        guard let data = char.data(using: .utf8) else { return }
        sendPacket(channel: .input, messageType: .keyStroke, payload: data)
    }
    
    
    public func requestDirectoryList(path: String = "~/") {
        guard let data = path.data(using: .utf8) else { return }
        sendPacket(channel: .fileTransfer, messageType: .fileDirectoryListReq, payload: data)
    }
    
    public func requestIDRKeyframe() {
        sendPacket(channel: .controlAndHandshake, messageType: .requestIDR, payload: Data())
    }
    
    private func sendPacket(channel: TailRemoteChannel, messageType: TailRemoteMessageType, payload: Data) {
        guard let connection = connection else { return }
        
        let message = NWProtocolFramer.Message(channel: channel, messageType: messageType)
        let context = NWConnection.ContentContext(identifier: "ClientPacket", metadata: [message])
        
        payload.withUnsafeBytes { rawBuffer in
            let dispatchData = DispatchData(bytes: rawBuffer)
            connection.send(content: dispatchData, contentContext: context, isComplete: true, completion: .idempotent)
        }
    }
}
