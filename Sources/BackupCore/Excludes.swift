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
    /// The patterns read once, ready to compare: checked for every file of a scan.
    private let compiled: [Compiled]

    private struct Compiled: Sendable {
        var pattern: String
        var glob: String
        var byPath: Bool
        var matchesFiles: Bool
        /// No wildcard or escape: fnmatch would compare the bytes, so they are compared directly
        var literal: Bool
    }

    public init(patterns: [String], paths: [String] = [], maxFileSize: Int64? = nil) {
        self.patterns = patterns.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        self.paths = Set(paths.map(Self.resolved))
        self.maxFileSize = maxFileSize
        compiled = self.patterns.map { pattern in
            // like .gitignore: a trailing "/" means a folder (they all match folders), a leading one the source root
            var p = pattern.hasSuffix("/") ? String(pattern.dropLast()) : pattern
            let byPath = p.contains("/")
            if byPath { p = p.hasPrefix("/") ? String(p.dropFirst()) : p }
            let last = (p as NSString).lastPathComponent
            return Compiled(pattern: pattern, glob: p, byPath: byPath,
                            matchesFiles: last.hasPrefix(".") || last.contains(where: { "*?[".contains($0) }),
                            literal: !p.contains(where: { "*?[\\".contains($0) }))
        }
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
        compiled.first { c in
            guard isDirectory || c.matchesFiles else { return false }
            let subject = c.byPath ? path ?? name : name
            // bytes, not String ==: "é" composed and decomposed are different names to fnmatch, and to the disk
            if c.literal { return subject.utf8.elementsEqual(c.glob.utf8) }
            return fnmatch(c.glob, subject, c.byPath ? FNM_PATHNAME : 0) == 0
        }?.pattern
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
        // the folders of older cloud clients, outside the Library: with the whole profile saved they would be
        // downloaded and backed up too
        list += CloudFolder.homeFolders(home: home).map { Automatic(path: $0.url.path, reason: "Cartella di \($0.service)") }
        // caches and downloads of developer tools, which they fetch again: restored they only cost time and space
        list += toolCaches.map { Automatic(path: home + "/" + $0.0, reason: $0.1) }
        return list
    }

    /// Relative to the home: only what a tool rebuilds or downloads again, never its settings.
    static let toolCaches = [
        (".cache", "Cache delle app a riga di comando"),
        (".npm", "Cache di npm"),
        (".bun/install/cache", "Cache di Bun"),
        (".cargo/registry", "Pacchetti scaricati da Cargo"),
        (".cargo/git", "Pacchetti scaricati da Cargo"),
        (".rustup/toolchains", "Versioni di Rust installate"),
        (".gradle/caches", "Cache di Gradle"),
        (".gradle/wrapper/dists", "Versioni di Gradle scaricate"),
        (".m2/repository", "Pacchetti scaricati da Maven"),
        ("go/pkg/mod", "Moduli scaricati da Go"),
        (".cocoapods/repos", "Indice di CocoaPods"),
        (".nvm/versions", "Versioni di Node installate"),
        (".pyenv/versions", "Versioni di Python installate"),
        (".electron-gyp", "Header scaricati da Electron"),
        (".vscode/extensions", "Estensioni di VS Code"),
        (".cursor/extensions", "Estensioni di Cursor"),
        (".ollama/models", "Modelli di Ollama"),
        (".thumbnails", "Anteprime"),
    ]
}

/// A folder holding a CACHEDIR.TAG (bford.info/cachedir) declares itself a cache that needn't be backed up.
func isCacheDirectory(_ path: String) -> Bool {
    let sig = Data("Signature: 8a477f597d28d172789f06886806bc55".utf8)
    guard let h = FileHandle(forReadingAtPath: path + "/CACHEDIR.TAG") else { return false }
    defer { try? h.close() }
    return (try? h.read(upToCount: sig.count)) == sig
}
