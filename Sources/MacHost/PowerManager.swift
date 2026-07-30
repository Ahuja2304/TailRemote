import Foundation

public final class PowerManager: ObservableObject {
    public static let shared = PowerManager()
    @Published public private(set) var isClamshellModeEnabled: Bool = false

    private init() {}

    public func enableClamshellMode() {
        let scriptSource = "do shell script \"pmset disablesleep 1\" with administrator privileges"
        executeScript(scriptSource) { success in
            DispatchQueue.main.async {
                if success {
                    self.isClamshellModeEnabled = true
                    print("⚡️ MacHost: Clamshell Mode ENABLED (pmset disablesleep 1)")
                } else {
                    print("❌ MacHost: Failed to enable Clamshell Mode")
                }
            }
        }
    }

    public func disableClamshellMode() {
        let scriptSource = "do shell script \"pmset disablesleep 0\" with administrator privileges"
        executeScript(scriptSource) { success in
            DispatchQueue.main.async {
                if success {
                    self.isClamshellModeEnabled = false
                    print("💤 MacHost: Clamshell Mode DISABLED (pmset disablesleep 0)")
                } else {
                    print("❌ MacHost: Failed to disable Clamshell Mode")
                }
            }
        }
    }

    private func executeScript(_ source: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            if let script = NSAppleScript(source: source) {
                script.executeAndReturnError(&error)
                completion(error == nil)
            } else {
                completion(false)
            }
        }
    }
}
