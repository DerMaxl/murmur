import Foundation
import ServiceManagement

/// Launch-at-login, backed by `SMAppService` (macOS 13+). Registers the app bundle
/// itself as a login item, so Murmur starts in the menu bar when you log in.
enum LoginItem {
    /// Whether the app is currently registered to launch at login.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Register or unregister the app as a login item. Best-effort: logs and no-ops
    /// on failure (e.g. running from an unsigned/loose build) rather than throwing.
    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            Log.error("Login item \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
    }
}
