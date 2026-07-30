import SwiftUI
import Network
import ApplicationServices



// MARK: - Observable Server State Controller

public final class MacHostServerState: ObservableObject {
    @Published public var isRunning: Bool = false
    @Published public var localHostName: String = "Quintessa.local"
    @Published public var port: UInt16 = 8088
    @Published public var udpPort: UInt16 = 8089
    @Published public var sessionPIN: String = "0000"
    
    private var server: MacHostServer?
    
    public init(port: UInt16 = 8088) {
        self.port = port
        if let hostName = Host.current().localizedName, !hostName.isEmpty {
            self.localHostName = hostName
        }
        self.sessionPIN = String(format: "%04d", Int.random(in: 0...9999))
        startServer()
    }
    
    public func startServer() {
        guard !isRunning else { return }
        
        let trusted = AXIsProcessTrusted()
        if !trusted {
            logPrint("⚠️ macOS System Warning: Accessibility permission is NOT granted!")
            logPrint("   To control mouse/keyboard from iPhone, open macOS System Settings > Privacy & Security > Accessibility and enable Terminal/MacHost.")
        } else {
            logPrint("✅ Accessibility Permission: GRANTED (Remote input control enabled)")
        }
        
        self.sessionPIN = String(format: "%04d", Int.random(in: 0...9999))
        let newServer = MacHostServer(port: port, udpPort: udpPort, sessionPIN: sessionPIN)
        do {
            try newServer.start()
            self.server = newServer
            self.isRunning = true
            logPrint("🟢 MacHost Dual Listener READY (TCP: \(port), UDP Video: \(udpPort)) [PIN: \(sessionPIN)]")
        } catch {
            logPrint("❌ Server Startup Error: \(error)")
            self.isRunning = false
        }
    }
    
    public func stopServer() {
        guard isRunning else { return }
        server?.stop()
        server = nil
        isRunning = false
        logPrint("🛑 MacHost Listener STOPPED on ports \(port) & \(udpPort)")
    }
    
    public func toggleServer() {
        if isRunning {
            stopServer()
        } else {
            startServer()
        }
    }
}

// MARK: - macOS Menu Bar Server App Entry Point

public final class MacHostAppDelegate: NSObject, NSApplicationDelegate {
    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        logPrint("🟢 MacHost: Set NSApp activation policy to .accessory (Menu Bar Agent)")
    }
}

@main
struct TailRemoteHostApp: App {
    @NSApplicationDelegateAdaptor(MacHostAppDelegate.self) var appDelegate
    @StateObject private var serverState = MacHostServerState(port: 8088)
    
    var body: some Scene {
        MenuBarExtra("TailRemote", systemImage: "antenna.radiowaves.left.and.right") {
            TailRemoteMenuBarView(serverState: serverState)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Mac Host Hybrid TCP + UDP Listener Server

public final class MacHostServer: @unchecked Sendable {
    private let port: UInt16
    private let udpPort: UInt16
    public let sessionPIN: String
    private var listener: NWListener?
    private var udpListener: NWListener?
    private var activeSession: MacHostSession?
    
    public var blockedIPs = Set<String>()
    public var failedAttempts: [String: Int] = [:]
    
    public init(port: UInt16 = 8088, udpPort: UInt16 = 8089, sessionPIN: String) {
        self.port = port
        self.udpPort = udpPort
        self.sessionPIN = sessionPIN
    }
    
    public func start() throws {
        // 1. TCP Control/Input Listener (Port 8088)
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        
        let framerOption = NWProtocolFramer.Options(definition: TailRemoteFramer.definition)
        parameters.defaultProtocolStack.applicationProtocols.insert(framerOption, at: 0)
        
        let nwListener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        self.listener = nwListener
        
        nwListener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        nwListener.start(queue: .global(qos: .userInteractive))
        
        // 2. UDP Video Datagram Listener (Port 8089)
        let udpParameters = NWParameters.udp
        let nwUDPListener = try NWListener(using: udpParameters, on: NWEndpoint.Port(rawValue: udpPort)!)
        self.udpListener = nwUDPListener
        
        nwUDPListener.newConnectionHandler = { [weak self] connection in
            logPrint("📡 MacHost: Incoming UDP video connection from \(connection.endpoint)")
            self?.activeSession?.assignUDPConnection(connection)
        }
        nwUDPListener.start(queue: .global(qos: .userInteractive))
    }
    
    public func stop() {
        activeSession?.stop()
        activeSession = nil
        listener?.cancel()
        listener = nil
        udpListener?.cancel()
        udpListener = nil
    }
    
    private func handleConnection(_ connection: NWConnection) {
        let clientIP = extractIPAddress(from: connection.endpoint)
        
        if blockedIPs.contains(clientIP) {
            logPrint("🚫 MacHost Gatekeeper: Blocked unauthorized connection attempt from IP \(clientIP)")
            connection.cancel()
            return
        }
        
        logPrint("📩 Incoming TCP connection from iPhone (\(connection.endpoint)). Initializing Gatekeeper authentication...")
        activeSession?.stop()
        let session = MacHostSession(connection: connection, expectedPIN: sessionPIN, server: self, clientIP: clientIP)
        self.activeSession = session
        session.start()
    }
    
    private func extractIPAddress(from endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, _):
            switch host {
            case .name(let name, _): return name
            case .ipv4(let address): return "\(address)"
            case .ipv6(let address): return "\(address)"
            @unknown default: return "unknown"
            }
        default:
            return "unknown"
        }
    }
}

// MARK: - Mac Host Active Session & Gatekeeper State Machine

public final class MacHostSession: @unchecked Sendable {
    public enum SessionAuthState {
        case waitingForAuth
        case authenticated
    }
    
    private let connection: NWConnection
    private var udpConnection: NWConnection?
    private let expectedPIN: String
    private unowned let server: MacHostServer
    private let clientIP: String
    
    private var state: SessionAuthState = .waitingForAuth
    private var videoPipeline: MacHostVideoPipeline?
    private let fileBroker = FileBroker()
    
    public init(connection: NWConnection, expectedPIN: String, server: MacHostServer, clientIP: String) {
        self.connection = connection
        self.expectedPIN = expectedPIN
        self.server = server
        self.clientIP = clientIP
    }
    
    public func assignUDPConnection(_ udpConnection: NWConnection) {
        self.udpConnection = udpConnection
        videoPipeline?.updateUDPConnection(udpConnection)
        udpConnection.start(queue: .global(qos: .userInteractive))
    }
    
    public func start() {
        connection.stateUpdateHandler = { [weak self] connectionState in
            switch connectionState {
            case .ready:
                logPrint("✅ MacHost: Client TCP socket connected (\(self?.clientIP ?? "unknown")). Awaiting 4-digit PIN Auth payload...")
                self?.receiveNextPacket()
            case .failed(let error):
                logPrint("❌ MacHost: Connection failed: \(error)")
                self?.stopCapturePipeline()
            case .cancelled:
                logPrint("ℹ️ MacHost: Connection cancelled")
                self?.stopCapturePipeline()
            default:
                break
            }
        }
        
        connection.start(queue: .global(qos: .userInteractive))
    }
    
    public func stop() {
        stopCapturePipeline()
        connection.cancel()
        udpConnection?.cancel()
        udpConnection = nil
    }
    
    private func startCapturePipeline() {
        let pipeline = MacHostVideoPipeline(connection: udpConnection)
        self.videoPipeline = pipeline
        
        Task {
            do {
                try await pipeline.startCapture()
                logPrint("🎥 MacHost: ScreenCaptureKit video pipeline started @ 60 FPS over UDP Transport")
            } catch {
                logPrint("❌ MacHost: Video pipeline start failed: \(error)")
            }
        }
    }
    
    private func stopCapturePipeline() {
        Task {
            await videoPipeline?.stopCapture()
            videoPipeline = nil
        }
    }
    
    // MARK: - Recursive TLV Packet Receiver Loop
    
    private func receiveNextPacket() {
        connection.receiveMessage { [weak self] content, context, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                logPrint("⚠️ MacHost: TLV packet receive error: \(error)")
                return
            }
            
            if let framerMessage = context?.protocolMetadata(definition: TailRemoteFramer.definition) as? NWProtocolFramer.Message,
               let msgTypeRaw = framerMessage.messageType,
               let msgType = TailRemoteMessageType(rawValue: msgTypeRaw) {
                
                self.processInboundTLV(type: msgType, payload: content ?? Data())
            }
            
            self.receiveNextPacket()
        }
    }
    
    // MARK: - Inbound TLV Payload Processing & Gatekeeper Enforcement
    
    private func processInboundTLV(type: TailRemoteMessageType, payload: Data) {
        switch state {
        case .waitingForAuth:
            if type == .authPIN {
                handleAuthenticationAttempt(payload: payload)
            } else {
                logPrint("⚠️ MacHost Gatekeeper: Dropped unauthenticated packet (Type 0x\(String(type.rawValue, radix: 16))) from \(clientIP)")
            }
            
        case .authenticated:
            switch type {
            case .mouseInput:
                videoPipeline?.forceInputWakeup()
                handleMouseInput(payload: payload)
            case .keyboardCommand:
                videoPipeline?.forceInputWakeup()
                handleKeyboardCommand(payload: payload)
            case .authPIN:
                logPrint("ℹ️ MacHost: Session authenticated.")
            case .videoFrame:
                break
            }
        }
    }
    
    private func handleAuthenticationAttempt(payload: Data) {
        let receivedPIN = String(data: payload, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        
        if receivedPIN == expectedPIN {
            logPrint("🔓 MacHost Gatekeeper: AUTHENTICATION SUCCESSFUL for client \(clientIP) with PIN '\(receivedPIN)'.")
            state = .authenticated
            server.failedAttempts[clientIP] = 0
            
            sendTLV(type: .authPIN, payload: Data([0x01]))
            startCapturePipeline()
        } else {
            let attempts = (server.failedAttempts[clientIP] ?? 0) + 1
            server.failedAttempts[clientIP] = attempts
            logPrint("⚠️ MacHost Gatekeeper: AUTHENTICATION FAILED for client \(clientIP) (Attempt \(attempts)/3, Provided: '\(receivedPIN)').")
            
            sendTLV(type: .authPIN, payload: Data([0x00]))
            
            if attempts >= 3 {
                logPrint("🚫 MacHost Gatekeeper: Brute-Force limit reached for IP \(clientIP). Blocking IP and terminating TCP connection.")
                server.blockedIPs.insert(clientIP)
                connection.cancel()
            }
        }
    }
    
    private func handleMouseInput(payload: Data) {
        guard payload.count >= 1 else { return }
        let subType = payload[0]
        
        switch subType {
        case 0x01:
            guard payload.count >= 9 else { return }
            let dxRaw = payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 1, as: UInt32.self) }
            let dyRaw = payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 5, as: UInt32.self) }
            let dx = Float(bitPattern: UInt32(bigEndian: dxRaw))
            let dy = Float(bitPattern: UInt32(bigEndian: dyRaw))
            MacInputInjector.injectRelativeMove(dx: dx, dy: dy)
            
        case 0x02:
            guard payload.count >= 9 else { return }
            let xRaw = payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 1, as: UInt32.self) }
            let yRaw = payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
            let normX = Float(bitPattern: UInt32(bigEndian: xRaw))
            let normY = Float(bitPattern: UInt32(bigEndian: yRaw))
            let mainBounds = CGDisplayBounds(CGMainDisplayID())
            MacInputInjector.injectAbsoluteMove(normalizedX: normX, normalizedY: normY, screenWidth: mainBounds.width, screenHeight: mainBounds.height)
            
        case 0x03:
            guard payload.count >= 3 else { return }
            if let button = MouseButtonType(rawValue: payload[1]),
               let state = MouseButtonState(rawValue: payload[2]) {
                MacInputInjector.injectMouseButton(button: button, state: state)
            }
            
        case 0x04:
            guard payload.count >= 9 else { return }
            let dxRaw = payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 1, as: UInt32.self) }
            let dyRaw = payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 5, as: UInt32.self) }
            let scrollDx = Float(bitPattern: UInt32(bigEndian: dxRaw))
            let scrollDy = Float(bitPattern: UInt32(bigEndian: dyRaw))
            MacInputInjector.injectScroll(scrollDx: scrollDx, scrollDy: scrollDy)
            
        default:
            break
        }
    }
    
    private func handleKeyboardCommand(payload: Data) {
        if let charStr = String(data: payload, encoding: .utf8) {
            MacInputInjector.injectKeystroke(charStr)
        }
    }
    
    private func sendTLV(type: TailRemoteMessageType, payload: Data) {
        let message = NWProtocolFramer.Message(type: type)
        let context = NWConnection.ContentContext(identifier: "HostTLV", metadata: [message])
        
        payload.withUnsafeBytes { rawBuffer in
            let dispatchData = DispatchData(bytes: rawBuffer)
            connection.send(content: dispatchData, contentContext: context, isComplete: true, completion: .idempotent)
        }
    }
}
