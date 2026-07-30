import SwiftUI
import AVFoundation

#if canImport(UIKit)
import UIKit
#endif

// MARK: - AVSampleBufferDisplayLayer UIViewRepresentable Wrapper

#if os(iOS)
public struct SampleBufferDisplayView: UIViewRepresentable {
    public let displayLayer: AVSampleBufferDisplayLayer
    
    public init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
    }
    
    public func makeUIView(context: Context) -> SampleBufferVideoLayerView {
        let view = SampleBufferVideoLayerView()
        view.videoLayer = displayLayer
        return view
    }
    
    public func updateUIView(_ uiView: SampleBufferVideoLayerView, context: Context) {
        uiView.setNeedsLayout()
    }
}

public final class SampleBufferVideoLayerView: UIView {
    public var videoLayer: AVSampleBufferDisplayLayer? {
        didSet {
            oldValue?.removeFromSuperlayer()
            if let layer = videoLayer {
                layer.frame = bounds
                self.layer.addSublayer(layer)
            }
        }
    }
    
    public override init(frame: CGRect) {
        super.init(frame: frame)
        self.backgroundColor = .black
    }
    
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.backgroundColor = .black
    }
    
    public override func layoutSubviews() {
        super.layoutSubviews()
        videoLayer?.frame = bounds
    }
}

// MARK: - Gatekeeper Keypad Overlay Component

public struct GatekeeperPinKeypadOverlayView: View {
    @State private var enteredPIN: String = ""
    public var authFailed: Bool = false
    public var onAuthenticate: ((String) -> Void)?
    
    public init(authFailed: Bool = false, onAuthenticate: ((String) -> Void)? = nil) {
        self.authFailed = authFailed
        self.onAuthenticate = onAuthenticate
    }
    
    public var body: some View {
        ZStack {
            Color.black.opacity(0.85)
                .ignoresSafeArea()
            
            VStack(spacing: 20) {
                // Header Icon & Title
                VStack(spacing: 6) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.blue)
                    
                    Text("Gatekeeper Protection")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    
                    Text("Enter 4-digit PIN displayed on MacHost")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                
                // PIN Code Boxes
                HStack(spacing: 16) {
                    ForEach(0..<4, id: \.self) { index in
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.white.opacity(0.15))
                                .frame(width: 50, height: 60)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(index < enteredPIN.count ? Color.blue : Color.white.opacity(0.2), lineWidth: 2)
                                )
                            
                            if index < enteredPIN.count {
                                let charIndex = enteredPIN.index(enteredPIN.startIndex, offsetBy: index)
                                Text(String(enteredPIN[charIndex]))
                                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                }
                
                if authFailed {
                    Text("⚠️ Invalid PIN. Try again (3 strikes = Block).")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.red)
                }
                
                // Numeric Keypad Grid
                let buttons: [[String]] = [
                    ["1", "2", "3"],
                    ["4", "5", "6"],
                    ["7", "8", "9"],
                    ["", "0", "⌫"]
                ]
                
                VStack(spacing: 12) {
                    ForEach(buttons, id: \.self) { row in
                        HStack(spacing: 20) {
                            ForEach(row, id: \.self) { item in
                                Button(action: {
                                    handleKeyPress(item)
                                }) {
                                    ZStack {
                                        Circle()
                                            .fill(item.isEmpty ? Color.clear : Color.white.opacity(0.2))
                                            .frame(width: 55, height: 55)
                                        
                                        Text(item)
                                            .font(.system(size: 22, weight: .bold))
                                            .foregroundColor(.white)
                                    }
                                }
                                .disabled(item.isEmpty)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .background(.ultraThinMaterial)
            .cornerRadius(24)
            .shadow(radius: 20)
            .frame(maxWidth: 380)
        }
    }
    
    private func handleKeyPress(_ key: String) {
        if key == "⌫" {
            if !enteredPIN.isEmpty {
                enteredPIN.removeLast()
            }
        } else if !key.isEmpty && enteredPIN.count < 4 {
            enteredPIN.append(key)
            if enteredPIN.count == 4 {
                let finalPIN = enteredPIN
                onAuthenticate?(finalPIN)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    enteredPIN = ""
                }
            }
        }
    }
}

// MARK: - Observable Workspace State

@Observable
public final class ImmersiveWorkspaceState {
    public enum InputMode {
        case trackpadRelative
        case directTouchAbsolute
    }
    
    public var inputMode: InputMode = .trackpadRelative
    public var isToolbarVisible: Bool = true
    public var isKeyboardPresented: Bool = false
    public var isFilePanelPresented: Bool = false
    public var isControlPanelVisible: Bool = false
    public var isConnected: Bool = true
    public var isAuthenticated: Bool = false
    public var authFailed: Bool = false
    public var currentLatencyMs: Double = 14.2
    
    private var autoHideTask: Task<Void, Never>?
    
    public init() {
        resetAutoHideTimer()
    }
    
    public func userInteracted() {
        if !isToolbarVisible {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isToolbarVisible = true
            }
        }
        resetAutoHideTimer()
    }
    
    public func resetAutoHideTimer() {
        autoHideTask?.cancel()
        autoHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            if !Task.isCancelled && !isKeyboardPresented && !isFilePanelPresented && !isControlPanelVisible {
                withAnimation(.easeInOut(duration: 0.4)) {
                    isToolbarVisible = false
                }
            }
        }
    }
}

// MARK: - High-Contrast Immersive iOS Workspace View

public struct iPhoneClientWorkspaceView: View {
    @State private var state = ImmersiveWorkspaceState()
    
    public let displayLayer: AVSampleBufferDisplayLayer
    public var isAuthenticated: Bool = false
    public var authFailed: Bool = false
    public var onAuthenticate: ((String) -> Void)?
    public var onRelativeMove: ((Float, Float) -> Void)?
    public var onAbsoluteMove: ((Float, Float) -> Void)?
    public var onMouseButton: ((MouseButtonType, MouseButtonState) -> Void)?
    public var onScroll: ((Float, Float) -> Void)?
    public var onKeystroke: ((String) -> Void)?
    public var onRequestDirectoryList: (() -> Void)?
    public var onRequestIDR: (() -> Void)?
    
    public init(
        displayLayer: AVSampleBufferDisplayLayer,
        isAuthenticated: Bool = false,
        authFailed: Bool = false,
        onAuthenticate: ((String) -> Void)? = nil,
        onRelativeMove: ((Float, Float) -> Void)? = nil,
        onAbsoluteMove: ((Float, Float) -> Void)? = nil,
        onMouseButton: ((MouseButtonType, MouseButtonState) -> Void)? = nil,
        onScroll: ((Float, Float) -> Void)? = nil,
        onKeystroke: ((String) -> Void)? = nil,
        onRequestDirectoryList: (() -> Void)? = nil,
        onRequestIDR: (() -> Void)? = nil
    ) {
        self.displayLayer = displayLayer
        self.isAuthenticated = isAuthenticated
        self.authFailed = authFailed
        self.onAuthenticate = onAuthenticate
        self.onRelativeMove = onRelativeMove
        self.onAbsoluteMove = onAbsoluteMove
        self.onMouseButton = onMouseButton
        self.onScroll = onScroll
        self.onKeystroke = onKeystroke
        self.onRequestDirectoryList = onRequestDirectoryList
        self.onRequestIDR = onRequestIDR
    }
    
    public var body: some View {
        ZStack {
            // Base Layer: Native AVSampleBufferDisplayLayer spanning full landscape bounds
            SampleBufferDisplayView(displayLayer: displayLayer)
                .ignoresSafeArea()
            
            // Touch & Trackpad Gesture Interaction Layer
            TailRemoteGestureView(
                mode: state.inputMode,
                onRelativeMove: onRelativeMove,
                onAbsoluteMove: onAbsoluteMove,
                onMouseButton: onMouseButton,
                onScroll: onScroll,
                onUserInteraction: {
                    state.userInteracted()
                }
            )
            .ignoresSafeArea()
            .defersSystemGestures(on: .all)
            
            // Native UIKeyInput Keystroke Catcher
            RemoteKeyboardCatcher(isFirstResponder: $state.isKeyboardPresented) { keystroke in
                onKeystroke?(keystroke)
            }
            .frame(width: 0, height: 0)
            
            // Top Floating Glassmorphic High-Contrast Toolbar Overlay
            VStack {
                if state.isToolbarVisible && isAuthenticated {
                    HStack(spacing: 16) {
                        // Latency & Connection Status Badge
                        HStack(spacing: 6) {
                            Circle()
                                .fill(state.isConnected ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Text("\(Int(state.currentLatencyMs))ms")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                        
                        Spacer()
                        
                        // Input Mode Selector (Trackpad / Direct Touch)
                        HStack(spacing: 4) {
                            Button(action: {
                                state.inputMode = .trackpadRelative
                                state.userInteracted()
                            }) {
                                Image(systemName: "hand.draw")
                                    .font(.system(size: 15, weight: .semibold))
                                    .padding(8)
                                    .background(state.inputMode == .trackpadRelative ? Color.white.opacity(0.3) : Color.clear)
                                    .clipShape(Circle())
                            }
                            
                            Button(action: {
                                state.inputMode = .directTouchAbsolute
                                state.userInteracted()
                            }) {
                                Image(systemName: "hand.tap")
                                    .font(.system(size: 15, weight: .semibold))
                                    .padding(8)
                                    .background(state.inputMode == .directTouchAbsolute ? Color.white.opacity(0.3) : Color.clear)
                                    .clipShape(Circle())
                            }
                        }
                        .padding(4)
                        .background(.regularMaterial, in: Capsule())
                        
                        // Control Panel Toggle
                        Button(action: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                state.isControlPanelVisible.toggle()
                            }
                            state.userInteracted()
                        }) {
                            Image(systemName: "sidebar.right")
                                .font(.system(size: 16, weight: .semibold))
                                .padding(10)
                                .background(.regularMaterial, in: Circle())
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                
                Spacer()
            }
            .allowsHitTesting(state.isToolbarVisible)
            
            // Phase 3: Gatekeeper PIN Handshake Keypad Overlay (Shown when connected but not authenticated)
            if !isAuthenticated {
                GatekeeperPinKeypadOverlayView(
                    authFailed: authFailed,
                    onAuthenticate: { pin in
                        onAuthenticate?(pin)
                    }
                )
                .transition(.opacity)
            }
        }
    }
}
#endif
