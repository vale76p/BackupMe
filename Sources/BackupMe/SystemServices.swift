import AppKit
import Foundation
import IOKit.ps
import ServiceManagement
import UserNotifications

enum SystemServices {
    // UNUserNotificationCenter crashes outside an app bundle (e.g. `swift run`)
    private static var hasBundle: Bool { Bundle.main.bundleIdentifier != nil }
    private static let presenter = ForegroundPresenter()

    static func requestNotificationPermission() {
        guard hasBundle else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = presenter
        center.setNotificationCategories([UNNotificationCategory(
            identifier: problemCategory,
            actions: [UNNotificationAction(identifier: Action.retry.rawValue, title: "Riprova"),
                      UNNotificationAction(identifier: Action.settings.rawValue, title: "Apri Impostazioni", options: [.foreground])],
            intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Buttons on problem notifications; the app wires them to a backup and to the settings window.
    enum Action: String { case retry, settings }
    @MainActor static var onAction: ((Action) -> Void)?
    private static let problemCategory = "problem"

    /// False when the user denied notifications: errors and the 3-day alert would then go unseen.
    static func notificationsAllowed() async -> Bool {
        guard hasBundle else { return true }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status != .denied
    }

    /// `problem` adds the Riprova / Apri Impostazioni buttons. All of them stack as one group in Notification Center.
    static func notify(_ title: String, _ body: String, problem: Bool = true) {
        guard hasBundle else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = "backupme"
        if problem { content.categoryIdentifier = problemCategory }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    static func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: power

    /// Why a scheduled backup should wait (Low Power Mode, battery under 20% unplugged, a hot Mac), or nil.
    static func backupDeferral() -> String? {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return "Risparmio energetico attivo" }
        if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue { return "Mac troppo caldo" }
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                  let level = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0,
                  level * 100 / max < 20 else { continue }
            return "Batteria sotto il 20%"
        }
        return nil
    }

    // MARK: windows

    /// A menu bar app has no Dock icon or menus: while one of its windows is open it acts as a regular app,
    /// so the window comes to the front, shows up in ⌘-Tab and gets the app menu (with Impostazioni… ⌘,).
    @MainActor static func windowOpened() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    /// Back to menu bar only once the last real window closes (the menu bar panel can't become main).
    @MainActor static func watchWindowsClosing() {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            let closing = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                if !NSApp.windows.contains(where: { ObjectIdentifier($0) != closing && $0.isVisible && $0.canBecomeMain }) {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    // MARK: single instance

    /// A login agent and a manual open can start two copies: the newer one quits.
    static func quitIfAlreadyRunning() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let me = NSRunningApplication.current
        if NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: {
            $0 != me && ($0.launchDate ?? .distantPast) <= (me.launchDate ?? .distantFuture)
        }) {
            exit(0)
        }
    }

    // MARK: launch at login

    private static let label = "com.vale76p.BackupMe"
    private static var agentPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/\(label).plist")
    }

    static var launchAtLogin: Bool { FileManager.default.fileExists(atPath: agentPlist.path) }

    /// A per-user LaunchAgent: started at login and restarted if it crashes (KeepAlive on unsuccessful exit),
    /// but not after "Esci". Works with an ad-hoc signature, unlike SMAppService. The plist is only written,
    /// not bootstrapped now: RunAtLoad would start a second copy immediately.
    static func setLaunchAtLogin(_ on: Bool) throws {
        try? SMAppService.mainApp.unregister() // clean up registrations from earlier versions
        guard on else {
            try? FileManager.default.removeItem(at: agentPlist)
            return
        }
        let installed = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications/BackupMe.app/Contents/MacOS/BackupMe")
        let exe = FileManager.default.fileExists(atPath: installed.path) ? installed.path : Bundle.main.executablePath
        guard let exe else { throw CocoaError(.fileNoSuchFile) }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
        ]
        try FileManager.default.createDirectory(at: agentPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: agentPlist)
    }
}

/// Shows notifications even while a BackupMe window is in front.
private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let action = SystemServices.Action(rawValue: response.actionIdentifier) else { return }
        await MainActor.run { SystemServices.onAction?(action) }
    }
}
