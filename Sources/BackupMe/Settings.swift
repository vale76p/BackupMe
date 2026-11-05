import BackupCore
import Foundation

struct AppSettings: Codable, Equatable {
    var sources: [String] = []
    var destination: String? = nil
    var intervalHours = 1
    var retention = RetentionPolicy()
    var capGB: Double? = nil
    var excludes = ExcludeRules.defaults
    var paused = false

    static let intervals = [1, 2, 4, 6, 12, 24]

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: "settings"),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "settings") }
    }

    var isConfigured: Bool { destination != nil && !sources.isEmpty }
}

enum AppPaths {
    static var support: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "BackupMe", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static var history: URL { support.appending(path: "history.json") }
    static func hashCache(_ computer: String) -> URL { support.appending(path: "hashcache-\(computer).json") }
    static func refsCache(_ computer: String) -> URL { support.appending(path: "refs-\(computer)", directoryHint: .isDirectory) }
    static var computerName: String { Host.current().localizedName ?? "Mac" }
}
