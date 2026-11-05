import Foundation
import ServiceManagement
import UserNotifications

enum SystemServices {
    // UNUserNotificationCenter crashes outside an app bundle (e.g. `swift run`)
    private static var hasBundle: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestNotificationPermission() {
        guard hasBundle else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(_ title: String, _ body: String) {
        guard hasBundle else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: launch at login

    private static var agentPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/com.vale76p.BackupMe.plist")
    }

    static var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled || FileManager.default.fileExists(atPath: agentPlist.path)
    }

    /// Tries SMAppService first; with an ad-hoc signature that can fail, so falls back to a LaunchAgent plist.
    /// The plist is only written, not bootstrapped: RunAtLoad would start a second copy right now.
    static func setLaunchAtLogin(_ on: Bool) throws {
        if on {
            do { try SMAppService.mainApp.register(); return } catch {}
            guard let exe = Bundle.main.executablePath else { throw CocoaError(.fileNoSuchFile) }
            let plist: [String: Any] = ["Label": "com.vale76p.BackupMe", "ProgramArguments": [exe], "RunAtLoad": true]
            try FileManager.default.createDirectory(at: agentPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: agentPlist)
        } else {
            try? SMAppService.mainApp.unregister()
            try? FileManager.default.removeItem(at: agentPlist)
        }
    }
}
