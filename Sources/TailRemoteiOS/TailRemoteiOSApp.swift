import SwiftUI

#if os(iOS)
@main
struct TailRemoteiOSApp: App {
    var body: some Scene {
        WindowGroup {
            TailRemoteAppView()
        }
    }
}

struct TailRemoteAppView: View {
    @StateObject private var connection = ClientConnectionManager()
    @State private var macAddress: String = "Quintessa.local"

    var body: some View {
        if connection.isConnected {
            iPhoneClientWorkspaceView(
                displayLayer: connection.displayLayer,
                isAuthenticated: connection.isAuthenticated,
                authFailed: connection.authFailed,
                onAuthenticate: { pin in connection.authenticate(pin: pin) },
                onRelativeMove: { dx, dy in connection.sendRelativeMove(dx: dx, dy: dy) },
                onAbsoluteMove: { x, y in connection.sendAbsoluteMove(normalizedX: x, normalizedY: y) },
                onMouseButton: { btn, state in connection.sendMouseButton(button: btn, state: state) },
                onScroll: { dx, dy in connection.sendScroll(scrollDx: dx, scrollDy: dy) },
                onKeystroke: { char in connection.sendKeystroke(char) },
                onRequestDirectoryList: { connection.requestDirectoryList() },
                onRequestIDR: { connection.requestIDRKeyframe() }
            )
        } else {
            VStack(spacing: 24) {
                Text("TailRemote iOS")
                    .font(.system(size: 32, weight: .bold))
                
                TextField("Mac Host IP / Quintessa.local", text: $macAddress)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 32)
                
                Button("Connect to Mac Host") {
                    connection.connect(host: macAddress, port: 8088)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }
}
#endif
