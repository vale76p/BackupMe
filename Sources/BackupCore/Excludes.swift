import Foundation

public struct ExcludeRules: Sendable {
    public static let defaults = ["node_modules", ".build", "DerivedData", "build", "dist", ".venv", "venv",
                                  "__pycache__", ".DS_Store", "Pods", ".gradle", "target"]
    public let patterns: [String]

    public init(patterns: [String]) {
        self.patterns = patterns.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// A pattern always matches folders. It matches files only if its last component has a wildcard (`*.log`)
    /// or starts with a dot (`.DS_Store`): a script named `build` or a file named `dist` is not a build folder.
    /// A pattern with "/" (`apps/*/dist`, `/build`) matches `path`, relative to the source; otherwise the name.
    public func excludes(name: String, isDirectory: Bool, path: String? = nil) -> Bool {
        patterns.contains { p in
            // like .gitignore: a trailing "/" means a folder (they all match folders), a leading one the source root
            var p = p.hasSuffix("/") ? String(p.dropLast()) : p
            let byPath = p.contains("/")
            if byPath { p = p.hasPrefix("/") ? String(p.dropFirst()) : p }
            let last = (p as NSString).lastPathComponent
            guard isDirectory || last.hasPrefix(".") || last.contains(where: { "*?[".contains($0) }) else { return false }
            return byPath ? fnmatch(p, path ?? name, FNM_PATHNAME) == 0 : fnmatch(p, name, 0) == 0
        }
    }
}

/// A folder holding a CACHEDIR.TAG (bford.info/cachedir) declares itself a cache that needn't be backed up.
func isCacheDirectory(_ path: String) -> Bool {
    let sig = Data("Signature: 8a477f597d28d172789f06886806bc55".utf8)
    guard let h = FileHandle(forReadingAtPath: path + "/CACHEDIR.TAG") else { return false }
    defer { try? h.close() }
    return (try? h.read(upToCount: sig.count)) == sig
}
