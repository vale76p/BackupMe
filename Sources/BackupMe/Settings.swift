import BackupCore
import Foundation

struct AppSettings: Codable, Equatable {
    var sources: [String] = []
    var destination: String? = nil
    var intervalHours = 1
    var retention = RetentionPolicy()
    var capGB: Double? = nil
    var excludes = ExcludeRules.defaults
    /// Specific folders or files left out, as absolute paths
    var excludedPaths: [String] = []
    var paused = false
    /// Files macOS won't let the user read are skipped silently and listed in Esclusioni.
    var skipUnreadable = true
    /// Files bigger than this are left out (an image disk or a VM would be stored whole at every change)
    var maxFileGB: Double? = nil
    /// The scheduled backup waits on a metered network (iPhone hotspot, Wi-Fi marked "a consumo")
    var deferOnMetered = true
    /// The scheduled backup waits while the Mac runs on battery, not only under 20%
    var onlyOnPower = false
    var notify = NotifyLevel.errors

    /// Problems (failed backups, a damaged archive, no backup for days) are always notified.
    enum NotifyLevel: String, Codable, CaseIterable { case errors, warnings, all }

    static let intervals = [1, 2, 4, 6, 12, 24]

    init() {}

    // missing keys keep their defaults, so an update that adds a setting never wipes the others
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sources = try c.decodeIfPresent([String].self, forKey: .sources) ?? sources
        destination = try c.decodeIfPresent(String.self, forKey: .destination)
        intervalHours = try c.decodeIfPresent(Int.self, forKey: .intervalHours) ?? intervalHours
        retention = try c.decodeIfPresent(RetentionPolicy.self, forKey: .retention) ?? retention
        capGB = try c.decodeIfPresent(Double.self, forKey: .capGB)
        excludes = try c.decodeIfPresent([String].self, forKey: .excludes) ?? excludes
        excludedPaths = try c.decodeIfPresent([String].self, forKey: .excludedPaths) ?? excludedPaths
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? paused
        skipUnreadable = try c.decodeIfPresent(Bool.self, forKey: .skipUnreadable) ?? skipUnreadable
        maxFileGB = try c.decodeIfPresent(Double.self, forKey: .maxFileGB)
        deferOnMetered = try c.decodeIfPresent(Bool.self, forKey: .deferOnMetered) ?? deferOnMetered
        onlyOnPower = try c.decodeIfPresent(Bool.self, forKey: .onlyOnPower) ?? onlyOnPower
        notify = (try? c.decodeIfPresent(NotifyLevel.self, forKey: .notify)) ?? notify
    }

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: "settings") else { return AppSettings() }
        if let s = try? JSONDecoder().decode(AppSettings.self, from: data) { return s }
        // keep what we could not read instead of overwriting it with empty settings on the next save
        UserDefaults.standard.set(data, forKey: "settings.unreadable")
        return AppSettings()
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "settings") }
    }

    var isConfigured: Bool { destination != nil && !sources.isEmpty }

    /// The rules a backup runs with: the patterns, the chosen paths and the automatic ones.
    var excludeRules: ExcludeRules {
        // clamp: Int64(x * 1e9) traps above ~9.2e9 GB
        ExcludeRules(patterns: excludes, paths: excludedPaths + ExcludeRules.automatic(destination: destination).map(\.path),
                     maxFileSize: maxFileGB.map { Int64(min($0, 1_000_000) * 1e9) })
    }

    /// Automatic exclusions inside a saved folder, only those on this Mac: no line for a cloud service it doesn't
    /// have. One inside another listed one (Library holds CloudStorage) is left out. `adding`: a source about to be saved.
    func automaticExclusions(adding extra: String? = nil) -> [ExcludeRules.Automatic] {
        let saved = sources + [extra].compactMap { $0 }
        let inside = ExcludeRules.automatic(destination: destination).filter { a in
            FileManager.default.fileExists(atPath: a.path) && saved.contains { a.path.hasPrefix($0 == "/" ? "/" : $0 + "/") }
        }
        return inside.filter { a in !inside.contains { a.path.hasPrefix($0.path + "/") } }
    }

    /// The source that already holds `path` and backs it up, unless a rule leaves it out there.
    func source(containing path: String) -> String? {
        let skipped = excludeRules.paths
        return sources.first { s in
            path.hasPrefix(s == "/" ? "/" : s + "/") && !skipped.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
    }
}

enum AppPaths {
    static var support: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "BackupMe", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static var history: URL { support.appending(path: "history.json") }
    static func hashCache(_ archive: String) -> URL { support.appending(path: "hashcache-\(archive).json") }
    /// One per destination: its manifests vanish from the listing whenever the user switches to another one.
    static func refsCache(_ archive: String, destination: String) -> URL {
        let key = sha256Hex(Data(destination.utf8)).prefix(12)
        return support.appending(path: "refs-\(archive)-\(key)", directoryHint: .isDirectory)
    }

    /// This Mac's archive folder name: computer name plus a piece of the hardware UUID, fixed at first use.
    /// Unique per Mac (two Macs with the same name never share an archive) and stable across renames.
    /// The saved name is kept per hardware UUID: Migration Assistant copies the preferences to a new Mac, and two
    /// Macs writing one archive would clean up each other's objects. A new name carries the account too, for the
    /// same reason (two users of one Mac backing up to one disk); a name already saved is kept with its archive.
    static let archiveName: String = {
        var uuid = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var wait = timespec(tv_sec: 1, tv_nsec: 0)
        let hostID = gethostuuid(&uuid, &wait) == 0 ? UUID(uuid: uuid).uuidString : nil
        let key = "archiveName-\(hostID ?? "unknown")"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        // the name this Mac saved before the key carried the UUID: kept if it was made here
        let legacy = UserDefaults.standard.string(forKey: "archiveName")
        let name = legacy.flatMap { old in hostID.map { old.hasSuffix("-" + $0.prefix(8)) } == true ? old : nil }
            ?? "\(Host.current().localizedName ?? "Mac")-\((hostID ?? UUID().uuidString).prefix(8))-\(NSUserName())"
        UserDefaults.standard.set(name, forKey: key)
        return name
    }()
}
