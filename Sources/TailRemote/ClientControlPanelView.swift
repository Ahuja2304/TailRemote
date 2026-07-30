import SwiftUI

#if os(iOS)
public struct ClientControlPanelView: View {
    public var onSpaceLeft: (() -> Void)?
    public var onMissionControl: (() -> Void)?
    public var onSpaceRight: (() -> Void)?
    public var onToggleBandwidth: (() -> Void)?
    public var onUserInteraction: (() -> Void)?
    
    @State private var isCmdActive: Bool = false
    @State private var isOptActive: Bool = false
    @State private var isCtrlActive: Bool = false
    @State private var isShiftActive: Bool = false
    @State private var isLowBandwidth: Bool = false

    public init(
        onSpaceLeft: (() -> Void)? = nil,
        onMissionControl: (() -> Void)? = nil,
        onSpaceRight: (() -> Void)? = nil,
        onToggleBandwidth: (() -> Void)? = nil,
        onUserInteraction: (() -> Void)? = nil
    ) {
        self.onSpaceLeft = onSpaceLeft
        self.onMissionControl = onMissionControl
        self.onSpaceRight = onSpaceRight
        self.onToggleBandwidth = onToggleBandwidth
        self.onUserInteraction = onUserInteraction
    }

    public var body: some View {
        VStack(spacing: 12) {
            // Space Navigation Group
            VStack(spacing: 10) {
                Button(action: {
                    onUserInteraction?()
                    onSpaceLeft?()
                }) {
                    Image(systemName: "arrow.left.square.fill")
                        .font(.system(size: 20, weight: .semibold))
                }
                
                Button(action: {
                    onUserInteraction?()
                    onMissionControl?()
                }) {
                    Image(systemName: "square.grid.3x3.fill")
                        .font(.system(size: 20, weight: .semibold))
                }
                
                Button(action: {
                    onUserInteraction?()
                    onSpaceRight?()
                }) {
                    Image(systemName: "arrow.right.square.fill")
                        .font(.system(size: 20, weight: .semibold))
                }
            }

            Rectangle()
                .fill(Color.white.opacity(0.3))
                .frame(width: 32, height: 1)

            // Modifier Toggles
            VStack(spacing: 8) {
                Button(action: {
                    onUserInteraction?()
                    isCmdActive.toggle()
                }) {
                    Text("⌘")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(isCmdActive ? Color.white.opacity(0.35) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                Button(action: {
                    onUserInteraction?()
                    isOptActive.toggle()
                }) {
                    Text("⌥")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(isOptActive ? Color.white.opacity(0.35) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                Button(action: {
                    onUserInteraction?()
                    isCtrlActive.toggle()
                }) {
                    Text("⌃")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(isCtrlActive ? Color.white.opacity(0.35) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                Button(action: {
                    onUserInteraction?()
                    isShiftActive.toggle()
                }) {
                    Text("⇧")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(isShiftActive ? Color.white.opacity(0.35) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            Rectangle()
                .fill(Color.white.opacity(0.3))
                .frame(width: 32, height: 1)

            // Performance / Low Bandwidth Toggle
            Button(action: {
                onUserInteraction?()
                isLowBandwidth.toggle()
                onToggleBandwidth?()
            }) {
                Image(systemName: isLowBandwidth ? "antenna.radiowaves.left.and.right.slash" : "antenna.radiowaves.left.and.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(isLowBandwidth ? .yellow : .white)
                    .frame(width: 32, height: 32)
                    .background(isLowBandwidth ? Color.yellow.opacity(0.25) : Color.clear)
                    .clipShape(Circle())
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .frame(width: 48)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 6, x: -2, y: 0)
        .foregroundColor(.white)
        .environment(\.colorScheme, .dark)
    }
}
#endif
