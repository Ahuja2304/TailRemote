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
#endif

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

#if os(iOS)
public struct iPhoneClientWorkspaceView: View {
    @State private var state = ImmersiveWorkspaceState()
    
    public let displayLayer: AVSampleBufferDisplayLayer
    public var onRelativeMove: ((Float, Float) -> Void)?
    public var onAbsoluteMove: ((Float, Float) -> Void)?
    public var onMouseButton: ((MouseButtonType, MouseButtonState) -> Void)?
    public var onScroll: ((Float, Float) -> Void)?
    public var onKeystroke: ((String) -> Void)?
    public var onRequestDirectoryList: (() -> Void)?
    public var onRequestIDR: (() -> Void)?
    
    public init(
        displayLayer: AVSampleBufferDisplayLayer,
        onRelativeMove: ((Float, Float) -> Void)? = nil,
        onAbsoluteMove: ((Float, Float) -> Void)? = nil,
        onMouseButton: ((MouseButtonType, MouseButtonState) -> Void)? = nil,
        onScroll: ((Float, Float) -> Void)? = nil,
        onKeystroke: ((String) -> Void)? = nil,
        onRequestDirectoryList: (() -> Void)? = nil,
        onRequestIDR: (() -> Void)? = nil
    ) {
        self.displayLayer = displayLayer
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
                if state.isToolbarVisible {
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
                        .foregroundColor(.white)
                        .padding(4)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                        
                        // File Transfer Panel Button
                        Button(action: {
                            state.isFilePanelPresented.toggle()
                            if state.isFilePanelPresented {
                                onRequestDirectoryList?()
                            }
                            state.userInteracted()
                        }) {
                            Image(systemName: "folder")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(10)
                                .background(state.isFilePanelPresented ? Color.white.opacity(0.3) : Color.clear)
                                .background(.regularMaterial, in: Circle())
                                .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                        }
                        
                        // Request IDR Keyframe Button (SFSymbol: arrow.clockwise.circle)
                        Button(action: {
                            onRequestIDR?()
                            state.userInteracted()
                        }) {
                            Image(systemName: "arrow.clockwise.circle")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(10)
                                .background(.regularMaterial, in: Circle())
                                .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                        }
                        
                        // Toggle Keyboard Button
                        Button(action: {
                            state.isKeyboardPresented.toggle()
                            state.userInteracted()
                        }) {
                            Image(systemName: "keyboard")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(10)
                                .background(state.isKeyboardPresented ? Color.white.opacity(0.3) : Color.clear)
                                .background(.regularMaterial, in: Circle())
                                .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                        }
                        
                        // Toggle Control Panel Button (Sidebar Right)
                        Button(action: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                state.isControlPanelVisible.toggle()
                            }
                            state.userInteracted()
                        }) {
                            Image(systemName: "sidebar.right")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(10)
                                .background(state.isControlPanelVisible ? Color.white.opacity(0.35) : Color.clear)
                                .background(.regularMaterial, in: Circle())
                                .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .environment(\.colorScheme, .dark)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                
                Spacer()
            }
            
            // Right-Side Compact Landscape Control Panel Overlay (Pinned to .trailing)
            HStack {
                Spacer()
                if state.isControlPanelVisible {
                    ClientControlPanelView(
                        onSpaceLeft: {
                            // Left Arrow Space Switch Action
                        },
                        onMissionControl: {
                            // Mission Control Action
                        },
                        onSpaceRight: {
                            // Right Arrow Space Switch Action
                        },
                        onToggleBandwidth: {
                            // Bandwidth Toggle Action
                        },
                        onUserInteraction: {
                            state.userInteracted()
                        }
                    )
                    .padding(.trailing, 10)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .allowsHitTesting(state.isControlPanelVisible)
        }
    }
}
#endif
