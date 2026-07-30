#if os(macOS)
import Foundation
import AppKit

// MARK: - System Command Types (Channel 0, Message 0x04)

public enum SystemCommandType: UInt8 {
    case lockScreen   = 0x01
    case setVolume    = 0x02
    case sleepSystem  = 0x03
}

// MARK: - macOS System Controller

public final class SystemController: @unchecked Sendable {
    public init() {}
    
    public func handleSystemCommand(data: Data) {
        guard let rawCommand = data.first,
              let command = SystemCommandType(rawValue: rawCommand) else { return }
        
        switch command {
        case .lockScreen:
            lockScreen()
        case .setVolume:
            if data.count >= 5 {
                let rawUInt = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 1, as: UInt32.self) }
                let volumeLevel = Float(bitPattern: UInt32(bigEndian: rawUInt))
                setVolume(level: volumeLevel)
            }
        case .sleepSystem:
            sleepSystem()
        }
    }
    
    public func lockScreen() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession")
        task.arguments = ["-suspend"]
        try? task.run()
    }
    
    public func setVolume(level: Float) {
        let percentage = Int(max(0.0, min(1.0, level)) * 100.0)
        let script = NSAppleScript(source: "set volume output volume \(percentage)")
        script?.executeAndReturnError(nil)
    }
    
    public func sleepSystem() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["displaysleepnow"]
        try? task.run()
    }
}
#endif
