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
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? paused
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
    static let archiveName: String = {
        if let saved = UserDefaults.standard.string(forKey: "archiveName") { return saved }
        var uuid = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var wait = timespec(tv_sec: 1, tv_nsec: 0)
        let hostID = gethostuuid(&uuid, &wait) == 0 ? UUID(uuid: uuid).uuidString : UUID().uuidString
        let name = "\(Host.current().localizedName ?? "Mac")-\(hostID.prefix(8))"
        UserDefaults.standard.set(name, forKey: "archiveName")
        return name
    }()
}
