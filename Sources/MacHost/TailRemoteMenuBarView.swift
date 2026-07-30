import SwiftUI

public struct TailRemoteMenuBarView: View {
    @ObservedObject var powerManager = PowerManager.shared
    @ObservedObject var serverState: MacHostServerState
    
    public init(serverState: MacHostServerState) {
        self.serverState = serverState
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header & Connection Status
            HStack(spacing: 8) {
                Circle()
                    .fill(serverState.isRunning ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(serverState.isRunning ? "TailRemote Server Active" : "TailRemote Server Stopped")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text("Host: \(serverState.localHostName):\(serverState.port)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.top, 2)

            // Gatekeeper Session PIN Badge
            if serverState.isRunning {
                VStack(spacing: 6) {
                    Text("GATEKEEPER AUTHENTICATION PIN")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 12) {
                        ForEach(Array(serverState.sessionPIN.enumerated()), id: \.offset) { _, char in
                            Text(String(char))
                                .font(.system(size: 22, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                                .frame(width: 36, height: 42)
                                .background(Color.blue)
                                .cornerRadius(8)
                                .shadow(radius: 2)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(10)
            }

            Divider()

            // Main Server Toggle Button
            Button(action: {
                serverState.toggleServer()
            }) {
                HStack {
                    Image(systemName: serverState.isRunning ? "stop.circle.fill" : "play.circle.fill")
                        .foregroundColor(serverState.isRunning ? .red : .green)
                        .font(.title3)
                    
                    Text(serverState.isRunning ? "Stop TailRemote Server" : "Start TailRemote Server")
                        .font(.body)
                        .fontWeight(.medium)
                }
            }
            .buttonStyle(.plain)

            // Clamshell Mode Toggle
            Toggle(isOn: Binding(
                get: { powerManager.isClamshellModeEnabled },
                set: { newValue in
                    if newValue {
                        powerManager.enableClamshellMode()
                    } else {
                        powerManager.disableClamshellMode()
                    }
                }
            )) {
                HStack(spacing: 6) {
                    Image(systemName: "laptopcomputer")
                        .foregroundColor(.accentColor)
                    Text("Prevent Lid-Close Sleep")
                        .font(.body)
                }
            }
            .toggleStyle(.switch)

            Divider()

            // Quit App Button
            Button(action: {
                if powerManager.isClamshellModeEnabled {
                    powerManager.disableClamshellMode()
                }
                serverState.stopServer()
                NSApplication.shared.terminate(nil)
            }) {
                HStack {
                    Image(systemName: "power")
                        .foregroundColor(.red)
                    Text("Quit TailRemote Host")
                        .foregroundColor(.red)
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 270)
    }
}
