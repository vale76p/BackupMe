import Foundation

public struct ExcludeRules: Sendable {
    public static let defaults = ["node_modules", ".build", "DerivedData", "build", "dist", ".venv", "venv",
                                  "__pycache__", ".DS_Store", "Pods", ".gradle", "target"]
    public let patterns: [String]
    /// Absolute paths left out wherever they are inside a saved item, symlinks resolved.
    /// A saved item is never left out by its own path: picking it as a source wins.
    public let paths: Set<String>
    /// Files bigger than this (bytes) are left out, never inside .git; nil means no limit.
    public let maxFileSize: Int64?

    public init(patterns: [String], paths: [String] = [], maxFileSize: Int64? = nil) {
        self.patterns = patterns.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        self.paths = Set(paths.map(Self.resolved))
        self.maxFileSize = maxFileSize
    }

    public static func resolved(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }

    public func excludes(name: String, isDirectory: Bool, path: String? = nil) -> Bool {
        matchingPattern(name: name, isDirectory: isDirectory, path: path) != nil
    }

    /// A pattern always matches folders. It matches files only if its last component has a wildcard (`*.log`)
    /// or starts with a dot (`.DS_Store`): a script named `build` or a file named `dist` is not a build folder.
    /// A pattern with "/" (`apps/*/dist`, `/build`) matches `path`, relative to the source; otherwise the name.
    /// Returns the first pattern that leaves the item out.
    public func matchingPattern(name: String, isDirectory: Bool, path: String? = nil) -> String? {
        patterns.first { p in
            // like .gitignore: a trailing "/" means a folder (they all match folders), a leading one the source root
            var p = p.hasSuffix("/") ? String(p.dropLast()) : p
            let byPath = p.contains("/")
            if byPath { p = p.hasPrefix("/") ? String(p.dropFirst()) : p }
            let last = (p as NSString).lastPathComponent
            guard isDirectory || last.hasPrefix(".") || last.contains(where: { "*?[".contains($0) }) else { return false }
            return byPath ? fnmatch(p, path ?? name, FNM_PATHNAME) == 0 : fnmatch(p, name, 0) == 0
        }
    }

    public enum Kind: Sendable { case folders, foldersAndFiles, path, rootPath }

    /// What a pattern matches, by the same reading as `matchingPattern`.
    public static func kind(of pattern: String) -> Kind {
        let p = pattern.hasSuffix("/") ? String(pattern.dropLast()) : pattern
        if p.hasPrefix("/") { return .rootPath }
        if p.contains("/") { return .path }
        return p.hasPrefix(".") || p.contains(where: { "*?[".contains($0) }) ? .foldersAndFiles : .folders
    }

    /// Why a new pattern can't be added, or nil if it can. A pattern matching any name would empty every backup.
    public static func problem(with pattern: String, in existing: [String]) -> String? {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        if p.isEmpty { return "Scrivi un nome o un pattern" }
        if existing.contains(p) { return "\(p) è già nell'elenco" }
        if p.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty { return "\(p) escluderebbe tutto" }
        let rules = ExcludeRules(patterns: [p])
        if rules.excludes(name: "qz7-progetto", isDirectory: true, path: "qz7-progetto") {
            return "\(p) escluderebbe ogni cartella, quindi tutto il backup"
        }
        return nil
    }

    /// What is always left out of a saved folder that contains it, with the reason shown in Settings.
    public struct Automatic: Sendable, Hashable {
        public var path: String
        public var reason: String
    }

    /// The destination (a backup must not save itself), the Library of the profile (it holds OneDrive, Dropbox and
    /// iCloud Drive, whose files are mostly online-only and would all be downloaded, plus app data and caches,
    /// largely unreadable without Full Disk Access, which would mark every backup as partial) and the Trash.
    public static func automatic(destination: String?, home: String = NSHomeDirectory()) -> [Automatic] {
        var list: [Automatic] = []
        if let destination { list.append(Automatic(path: destination, reason: "Destinazione dei backup")) }
        // the reasons name only the services on this Mac; the paths stay, so a client installed later is left out too
        let cloud = CloudFolder.installed(home: home)
        let inStorage = CloudFolder.serviceList(cloud.filter { $0.url.path.hasPrefix(home + "/Library/CloudStorage/") })
        let inLibrary = CloudFolder.serviceList(cloud.filter { $0.url.path.hasPrefix(home + "/Library/") })
        list += [
            Automatic(path: home + "/Library", reason: "Libreria: " + (inLibrary.map { $0 + ", " } ?? "") + "dati delle app e cache"),
            Automatic(path: home + "/Library/CloudStorage", reason: inStorage.map { "Cartelle di " + $0 } ?? "Cartelle dei servizi cloud"),
            Automatic(path: home + "/Library/Mobile Documents", reason: "iCloud Drive"),
            Automatic(path: home + "/.Trash", reason: "Cestino"),
        ]
        return list
    }
}

/// A folder holding a CACHEDIR.TAG (bford.info/cachedir) declares itself a cache that needn't be backed up.
func isCacheDirectory(_ path: String) -> Bool {
    let sig = Data("Signature: 8a477f597d28d172789f06886806bc55".utf8)
    guard let h = FileHandle(forReadingAtPath: path + "/CACHEDIR.TAG") else { return false }
    defer { try? h.close() }
    return (try? h.read(upToCount: sig.count)) == sig
}
