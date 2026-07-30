import Foundation
import Network
import AVFoundation
import QuartzCore
import os.log

private let logger = OSLog(subsystem: "com.tailremote", category: "JitterBuffer")

// MARK: - Phase 2: Aggressive 33ms TTL Out-of-Order UDP Jitter Buffer

public final class UDPFrameJitterBuffer: @unchecked Sendable {
    private struct FrameAssemblySlot {
        var fragments: [UInt16: Data] = [:]
        var totalFragments: UInt16
        var timestamp: Date = Date()
    }
    
    private var buffer: [UInt32: FrameAssemblySlot] = [:]
    private var latestCompletedFrameID: UInt32 = 0
    private let lock = NSLock()
    private let ttlSeconds: TimeInterval = 0.033 // Strict 33ms Time-To-Live threshold
    
    public init() {}
    
    public func ingestFragment(header: UDPVideoDatagramHeader, payload: Data) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        
        let frameID = header.frameID
        
        // 1. Instant Stale Purge: If fragment is from an older frame than already decoded, drop immediately
        if frameID <= latestCompletedFrameID {
            return nil
        }
        
        // 2. Aggressive Frame Purge: Purge all older incomplete frames (< frameID) to prioritize freshest frame
        purgeOlderSlots(than: frameID)
        
        // 3. TTL Check: Purge any expired slot older than 33ms
        if let existingSlot = buffer[frameID], Date().timeIntervalSince(existingSlot.timestamp) > ttlSeconds {
            buffer.removeValue(forKey: frameID)
            return nil
        }
        
        var slot = buffer[frameID] ?? FrameAssemblySlot(fragments: [:], totalFragments: header.totalFragments, timestamp: Date())
        slot.fragments[header.fragmentID] = payload
        buffer[frameID] = slot
        
        // 4. Complete Frame Assembly
        if slot.fragments.count == Int(header.totalFragments) {
            var reassembledFrame = Data()
            for fragIndex in 0..<header.totalFragments {
                if let fragData = slot.fragments[fragIndex] {
                    reassembledFrame.append(fragData)
                } else {
                    return nil
                }
            }
            
            latestCompletedFrameID = frameID
            buffer.removeValue(forKey: frameID)
            
            let timestamp = CACurrentMediaTime()
            os_log("UDP Frame %u fully reassembled and passed to decoder at %.6f", log: logger, type: .info, frameID, timestamp)
            
            return reassembledFrame
        }
        
        return nil
    }
    
    private func purgeOlderSlots(than currentFrameID: UInt32) {
        let now = Date()
        let keysToRemove = buffer.keys.filter { $0 < currentFrameID || now.timeIntervalSince(buffer[$0]?.timestamp ?? now) > ttlSeconds }
        for key in keysToRemove {
            buffer.removeValue(forKey: key)
        }
    }
}

// MARK: - iOS Client Connection Manager & Non-Blocking Hybrid Network Controller

@MainActor
public final class ClientConnectionManager: ObservableObject {
    @Published public var isConnected: Bool = false
    @Published public var isAuthenticated: Bool = false
    @Published public var authFailed: Bool = false
    @Published public var hostIP: String = "Quintessa.local"
    @Published public var port: UInt16 = 8088
    @Published public var udpPort: UInt16 = 8089
    @Published public var remoteFiles: [String] = []
    
    public let displayLayer = AVSampleBufferDisplayLayer()
    private var decoder: iPhoneClientVideoDecoder?
    
    private var tcpConnection: NWConnection?
    private var udpConnection: NWConnection?
    private let jitterBuffer = UDPFrameJitterBuffer()
    
    public init() {
        let videoDecoder = iPhoneClientVideoDecoder(displayLayer: displayLayer)
        self.decoder = videoDecoder
        videoDecoder.onRequestIDRKeyframe = { [weak self] in
            Task { @MainActor in
                self?.requestIDRKeyframe()
            }
        }
    }
    
    public func connect(host: String, port: UInt16 = 8088, udpPort: UInt16 = 8089) {
        self.hostIP = host
        self.port = port
        self.udpPort = udpPort
        self.isAuthenticated = false
        self.authFailed = false
        
        let targetHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 1. TCP Control/Input Connection
        let tcpEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(targetHost), port: NWEndpoint.Port(rawValue: port)!)
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let tcpParameters = NWParameters(tls: nil, tcp: tcpOptions)
        
        let framerOption = NWProtocolFramer.Options(definition: TailRemoteFramer.definition)
        tcpParameters.defaultProtocolStack.applicationProtocols.insert(framerOption, at: 0)
        
        let nwTCPConnection = NWConnection(to: tcpEndpoint, using: tcpParameters)
        self.tcpConnection = nwTCPConnection
        
        nwTCPConnection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    print("✅ iPhone: Connected TCP Control Channel (\(targetHost):\(port)).")
                    self?.isConnected = true
                    self?.receiveNextTCP()
                case .failed(let error):
                    print("❌ iPhone: TCP Connection failed: \(error)")
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
        
        nwTCPConnection.start(queue: .global(qos: .userInteractive))
        
        // 2. UDP Video Connection
        let udpEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(targetHost), port: NWEndpoint.Port(rawValue: udpPort)!)
        let nwUDPConnection = NWConnection(to: udpEndpoint, using: .udp)
        self.udpConnection = nwUDPConnection
        
        nwUDPConnection.stateUpdateHandler = { state in
            if state == .ready {
                print("📡 iPhone: UDP Video Socket READY (\(targetHost):\(udpPort)).")
            }
        }
        
        nwUDPConnection.start(queue: .global(qos: .userInteractive))
        receiveNextUDP()
    }
    
    public func disconnect() {
        tcpConnection?.cancel()
        tcpConnection = nil
        udpConnection?.cancel()
        udpConnection = nil
        isConnected = false
        isAuthenticated = false
        authFailed = false
    }
    
    // MARK: - Handshake PIN Authenticator (TCP TLV Type 0x01)
    
    public func authenticate(pin: String) {
        guard let pinData = pin.data(using: .utf8) else { return }
        sendTCP(type: .authPIN, payload: pinData)
    }
    
    // MARK: - TCP Receiver Loop
    
    private func receiveNextTCP() {
        guard let connection = tcpConnection else { return }
        
        connection.receiveMessage { [weak self] content, context, isComplete, error in
            guard let self = self, error == nil, let content = content else { return }
            
            if let framerMessage = context?.protocolMetadata(definition: TailRemoteFramer.definition) as? NWProtocolFramer.Message,
               let msgTypeRaw = framerMessage.messageType,
               let msgType = TailRemoteMessageType(rawValue: msgTypeRaw) {
                
                Task { @MainActor in
                    self.processInboundTCP(type: msgType, payload: content)
                }
            }
            
            Task { @MainActor in
                self.receiveNextTCP()
            }
        }
    }
    
    private func processInboundTCP(type: TailRemoteMessageType, payload: Data) {
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
        default:
            break
        }
    }
    
    // MARK: - UDP Video Receiver Loop
    
    private func receiveNextUDP() {
        guard let udpConnection = udpConnection else { return }
        
        udpConnection.receive(minimumIncompleteLength: 1, maximumLength: 2048) { [weak self] content, context, isComplete, error in
            guard let self = self else { return }
            
            if let data = content, let parsed = UDPVideoDatagramHeader.parse(from: data) {
                if let completeFrame = self.jitterBuffer.ingestFragment(header: parsed.header, payload: parsed.payload) {
                    Task { @MainActor in
                        self.processCompleteVideoFrame(payload: completeFrame)
                    }
                }
            }
            
            Task { @MainActor in
                self.receiveNextUDP()
            }
        }
    }
    
    private func processCompleteVideoFrame(payload: Data) {
        guard payload.count >= 1 else { return }
        let subType = payload[0]
        let videoData = payload.subdata(in: 1..<payload.count)
        
        switch subType {
        case 0x01:
            decoder?.handleFormatDescription(data: videoData)
        case 0x02:
            decoder?.handleVideoFrame(data: videoData, isKeyframe: true)
        case 0x03:
            decoder?.handleVideoFrame(data: videoData, isKeyframe: false)
        default:
            break
        }
    }
    
    // MARK: - Non-Blocking Background TCP Sends (Input Events)
    
    public func sendRelativeMove(dx: Float, dy: Float) {
        var payload = Data([0x01])
        var dxBE = dx.bitPattern.bigEndian
        var dyBE = dy.bitPattern.bigEndian
        withUnsafeBytes(of: &dxBE) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &dyBE) { payload.append(contentsOf: $0) }
        sendTCP(type: .mouseInput, payload: payload)
    }
    
    public func sendAbsoluteMove(normalizedX: Float, normalizedY: Float) {
        var payload = Data([0x02])
        var xBE = normalizedX.bitPattern.bigEndian
        var yBE = normalizedY.bitPattern.bigEndian
        withUnsafeBytes(of: &xBE) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &yBE) { payload.append(contentsOf: $0) }
        sendTCP(type: .mouseInput, payload: payload)
    }
    
    public func sendMouseButton(button: MouseButtonType, state: MouseButtonState) {
        let payload = Data([0x03, button.rawValue, state.rawValue])
        sendTCP(type: .mouseInput, payload: payload)
    }
    
    public func sendScroll(scrollDx: Float, scrollDy: Float) {
        var payload = Data([0x04])
        var dxBE = scrollDx.bitPattern.bigEndian
        var dyBE = scrollDy.bitPattern.bigEndian
        withUnsafeBytes(of: &dxBE) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &dyBE) { payload.append(contentsOf: $0) }
        sendTCP(type: .mouseInput, payload: payload)
    }
    
    public func sendKeystroke(_ char: String) {
        guard let data = char.data(using: .utf8) else { return }
        sendTCP(type: .keyboardCommand, payload: data)
    }
    
    public func requestKeystroke(_ char: String) {
        sendKeystroke(char)
    }
    
    public func requestDirectoryList(path: String = "~/") {
        guard let data = path.data(using: .utf8) else { return }
        sendTCP(type: .authPIN, payload: data)
    }
    
    public func requestIDRKeyframe() {
        sendTCP(type: .authPIN, payload: Data("PING".utf8))
    }
    
    private func sendTCP(type: TailRemoteMessageType, payload: Data) {
        guard let connection = tcpConnection else { return }
        
        let message = NWProtocolFramer.Message(type: type)
        let context = NWConnection.ContentContext(identifier: "ClientTCP", metadata: [message])
        
        payload.withUnsafeBytes { rawBuffer in
            let dispatchData = DispatchData(bytes: rawBuffer)
            connection.send(content: dispatchData, contentContext: context, isComplete: true, completion: .idempotent)
        }
    }
}
