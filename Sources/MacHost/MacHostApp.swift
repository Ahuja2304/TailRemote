import SwiftUI
import Network
import ApplicationServices
import TailRemote

// MARK: - Unbuffered Logging Helper

public func logPrint(_ msg: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let formatted = "[\(timestamp)] \(msg)\n"
    fputs(formatted, stdout)
    fflush(stdout)
}

// MARK: - Observable Server State Controller

public final class MacHostServerState: ObservableObject {
    @Published public var isRunning: Bool = false
    @Published public var localHostName: String = "Quintessa.local"
    @Published public var port: UInt16 = 8088
    
    private var server: MacHostServer?
    
    public init(port: UInt16 = 8088) {
        self.port = port
        if let hostName = Host.current().localizedName, !hostName.isEmpty {
            self.localHostName = hostName
        }
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
        
        let newServer = MacHostServer(port: port)
        do {
            try newServer.start()
            self.server = newServer
            self.isRunning = true
            logPrint("🟢 MacHost Listener READY on port \(port) (Waiting for iPhone connection...)")
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
        logPrint("🛑 MacHost Listener STOPPED on port \(port)")
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
        // Enforce macOS Menu Bar Accessory Activation Policy (hides Dock icon & pins to Menu Bar)
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

// MARK: - Mac Host TCP Listener Server

public final class MacHostServer: @unchecked Sendable {
    private let port: UInt16
    private var listener: NWListener?
    private var activeSession: MacHostSession?
    
    public init(port: UInt16 = 8088) {
        self.port = port
    }
    
    public func start() throws {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        
        let framerOption = NWProtocolFramer.Options(definition: TailRemoteFramer.definition)
        parameters.defaultProtocolStack.applicationProtocols.insert(framerOption, at: 0)
        
        let nwListener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        self.listener = nwListener
        
        nwListener.newConnectionHandler = { [weak self] connection in
            logPrint("📩 Incoming TCP connection from iPhone (\(connection.endpoint))...")
            self?.handleConnection(connection)
        }
        
        nwListener.start(queue: .global(qos: .userInteractive))
    }
    
    public func stop() {
        activeSession?.stop()
        activeSession = nil
        listener?.cancel()
        listener = nil
    }
    
    private func handleConnection(_ connection: NWConnection) {
        activeSession?.stop()
        let session = MacHostSession(connection: connection)
        self.activeSession = session
        session.start()
    }
}

// MARK: - Mac Host Active Session Pipeline

public final class MacHostSession: @unchecked Sendable {
    private let connection: NWConnection
    private var videoPipeline: MacHostVideoPipeline?
    private let fileBroker = FileBroker()
    
    public init(connection: NWConnection) {
        self.connection = connection
    }
    
    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                logPrint("✅ MacHost: Client connected successfully from \(self?.connection.endpoint.debugDescription ?? "unknown")")
                self?.startCapturePipeline()
                self?.receiveNextPacket()
            case .failed(let error):
                logPrint("❌ MacHost: Connection failed: \(error)")
                self?.stopCapturePipeline()
            case .cancelled:
                logPrint("ℹ️ MacHost: Connection cancelled")
                self?.stopCapturePipeline()
            case .preparing:
                logPrint("🔄 MacHost: Connection state changed to preparing")
            default:
                break
            }
        }
        
        connection.start(queue: .global(qos: .userInteractive))
    }
    
    public func stop() {
        stopCapturePipeline()
        connection.cancel()
    }
    
    private func startCapturePipeline() {
        let pipeline = MacHostVideoPipeline(connection: connection)
        self.videoPipeline = pipeline
        
        Task {
            do {
                try await pipeline.startCapture()
                logPrint("🎥 MacHost: ScreenCaptureKit video pipeline started @ 60 FPS")
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
    
    // MARK: - Packet Receiver Loop
    
    private func receiveNextPacket() {
        connection.receiveMessage { [weak self] content, context, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                logPrint("⚠️ MacHost: Packet receive error: \(error)")
                return
            }
            
            if let framerMessage = context?.protocolMetadata(definition: TailRemoteFramer.definition) as? NWProtocolFramer.Message,
               let channelID = framerMessage.channelID,
               let messageType = framerMessage.messageType {
                
                self.processInboundPacket(channelID: channelID, messageType: messageType, payload: content ?? Data())
            }
            
            self.receiveNextPacket()
        }
    }
    
    private func processInboundPacket(channelID: UInt8, messageType: UInt8, payload: Data) {
        guard let channel = TailRemoteChannel(rawValue: channelID),
              let msgType = TailRemoteMessageType(rawValue: messageType) else { return }
        
        switch channel {
        case .controlAndHandshake:
            if msgType == .requestIDR {
                logPrint("⚡️ MacHost: Received RequestIDR Keyframe request from iPhone. Forcing keyframe...")
                videoPipeline?.forceKeyframe()
            }
        case .input:
            handleInputEvent(messageType: msgType, payload: payload)
        case .fileTransfer:
            if msgType == .fileDirectoryListReq {
                handleDirectoryListRequest(payload: payload)
            }
        default:
            break
        }
    }
    
    private func handleInputEvent(messageType: TailRemoteMessageType, payload: Data) {
        switch messageType {
        case .pointerMoveRelative:
            guard payload.count >= 8 else { return }
            let dxRaw = payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
            let dyRaw = payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
            let dx = Float(bitPattern: UInt32(bigEndian: dxRaw))
            let dy = Float(bitPattern: UInt32(bigEndian: dyRaw))
            MacInputInjector.injectRelativeMove(dx: dx, dy: dy)
            logPrint("🖱️ MacHost: Injected relative mouse move (dx: \(dx), dy: \(dy))")
            
        case .pointerMoveAbsolute:
            guard payload.count >= 8 else { return }
            let xRaw = payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
            let yRaw = payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
            let normX = Float(bitPattern: UInt32(bigEndian: xRaw))
            let normY = Float(bitPattern: UInt32(bigEndian: yRaw))
            
            let mainDisplayBounds = CGDisplayBounds(CGMainDisplayID())
            MacInputInjector.injectAbsoluteMove(normalizedX: normX, normalizedY: normY, screenWidth: mainDisplayBounds.width, screenHeight: mainDisplayBounds.height)
            logPrint("🎯 MacHost: Injected absolute mouse move (x: \(normX), y: \(normY))")
            
        case .mouseButton:
            guard payload.count >= 2 else { return }
            let buttonRaw = payload[0]
            let stateRaw = payload[1]
            if let button = MouseButtonType(rawValue: buttonRaw),
               let state = MouseButtonState(rawValue: stateRaw) {
                MacInputInjector.injectMouseButton(button: button, state: state)
                logPrint("🖱️ MacHost: Injected mouse button click (\(button) - \(state))")
            }
            
        case .scrollEvent:
            guard payload.count >= 8 else { return }
            let dxRaw = payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
            let dyRaw = payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
            let scrollDx = Float(bitPattern: UInt32(bigEndian: dxRaw))
            let scrollDy = Float(bitPattern: UInt32(bigEndian: dyRaw))
            MacInputInjector.injectScroll(scrollDx: scrollDx, scrollDy: scrollDy)
            logPrint("📜 MacHost: Injected scroll event (dx: \(scrollDx), dy: \(scrollDy))")
            
        case .keyStroke:
            if let charStr = String(data: payload, encoding: .utf8) {
                MacInputInjector.injectKeystroke(charStr)
                logPrint("⌨️ MacHost: Injected keystroke '\(charStr)' to macOS system")
            }
            
        default:
            break
        }
    }
    
    private func handleDirectoryListRequest(payload: Data) {
        let requestedPath = String(data: payload, encoding: .utf8) ?? "~/"
        let expandedPath = NSString(string: requestedPath).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)
        Task {
            if let files = try? await fileBroker.listDirectory(at: url),
               let responseData = try? JSONEncoder().encode(files) {
                sendPacket(channel: .fileTransfer, messageType: .fileDirectoryListResp, payload: responseData)
                logPrint("📁 MacHost: Sent directory list (\(files.count) items) for path '\(requestedPath)'")
            }
        }
    }
    
    private func sendPacket(channel: TailRemoteChannel, messageType: TailRemoteMessageType, payload: Data) {
        let message = NWProtocolFramer.Message(channel: channel, messageType: messageType)
        let context = NWConnection.ContentContext(identifier: "HostPacket", metadata: [message])
        
        payload.withUnsafeBytes { rawBuffer in
            let dispatchData = DispatchData(bytes: rawBuffer)
            connection.send(content: dispatchData, contentContext: context, isComplete: true, completion: .idempotent)
        }
    }
}
