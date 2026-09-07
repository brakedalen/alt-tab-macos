import Cocoa
import ServiceManagement

/// SMAppService identifies this bundle directly; no legacy login items are inspected or migrated.
enum LoginItem {
    static func applyCurrentPreference(userInitiated: Bool = false) {
        let service = SMAppService.mainApp
        do {
            if Preferences.startAtLogin {
                if service.status == .notRegistered || service.status == .notFound { try service.register() }
                if service.status == .requiresApproval && userInitiated {
                    SMAppService.openSystemSettingsLoginItems()
                }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
        } catch {
            Logger.error { "Failed to change login item for \(App.bundleIdentifier): \(error)" }
            if userInitiated {
                let alert = NSAlert()
                alert.messageText = "Could not change Start at login"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
}
