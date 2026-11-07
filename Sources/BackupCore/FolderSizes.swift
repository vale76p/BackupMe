import Foundation

/// What a backup of a folder would save, and where it is: files and bytes, per folder at its top two levels.
public struct SizeScan: Sendable, Equatable {
    public struct Folder: Sendable, Equatable {
        /// Absolute path, as `ExcludeRules.paths` would take it.
        public var path: String
        public var files = 0
        public var bytes: Int64 = 0
        /// The folders inside it, biggest first; empty below the top level.
        public var children: [Folder] = []
    }

    public var files = 0
    public var bytes: Int64 = 0
    /// The folders at the top of the source, biggest first.
    public var folders: [Folder] = []

    /// Below this a folder isn't worth a row: what is saved is counted in the totals all the same.
    public static let notable: Int64 = 100_000_000

    /// Measures `source` skipping what the backup skips (see BackupEngine.walk): the rules, a CACHEDIR.TAG,
    /// folders and files only in the cloud. Reads metadata only. nil when cancelled or the folder can't be listed.
    public static func measure(_ source: String, rules: ExcludeRules, isCancelled: () -> Bool = { false }) -> SizeScan? {
        guard (try? FileManager.default.contentsOfDirectory(atPath: source)) != nil else { return nil }
        let resolved = ExcludeRules.resolved(source)
        var scan = SizeScan()
        // per top-level folder: its totals, and those of each folder inside it
        var tops: [String: (Folder, [String: Folder])] = [:]
        var cancelled = false

        func walk(_ rel: String, insideGit: Bool) {
            if cancelled || isCancelled() { cancelled = true; return }
            let full = rel.isEmpty ? source : source + "/" + rel
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: full) else { return }
            for name in names {
                guard let st = FileStat(path: full + "/" + name) else { continue }
                let path = rel.isEmpty ? name : rel + "/" + name
                let isDir = st.kind == .directory
                let tooBig = st.kind == .file && rules.maxFileSize.map { st.size > $0 } == true
                if !insideGit, rules.excludes(name: name, isDirectory: isDir, path: path) || rules.paths.contains(resolved + "/" + path)
                    || (isDir && isCacheDirectory(full + "/" + name)) || tooBig { continue }
                if st.dataless { continue } // only in the cloud: nothing to copy, and listing it would download it
                if isDir { walk(path, insideGit: insideGit || name == ".git"); continue }
                guard st.kind == .file else { continue }
                scan.files += 1; scan.bytes += st.size
                let parts = path.split(separator: "/", maxSplits: 2).map(String.init)
                guard parts.count > 1 else { continue } // a file at the top: in the totals only
                var (top, children) = tops[parts[0]] ?? (Folder(path: source + "/" + parts[0]), [:])
                top.files += 1; top.bytes += st.size
                if parts.count > 2 {
                    var child = children[parts[1]] ?? Folder(path: top.path + "/" + parts[1])
                    child.files += 1; child.bytes += st.size
                    children[parts[1]] = child
                }
                tops[parts[0]] = (top, children)
            }
        }
        walk("", insideGit: false)
        if cancelled { return nil }
        scan.folders = tops.values.map { top, children in
            var f = top
            f.children = children.values.sorted { $0.bytes > $1.bytes }
            return f
        }.sorted { $0.bytes > $1.bytes }
        return scan
    }

    /// The totals once `excluded` (absolute paths) are left out too: only the folders measured here count.
    public func remaining(excluding excluded: Set<String>) -> (files: Int, bytes: Int64) {
        var r = (files: files, bytes: bytes)
        for top in folders {
            if excluded.contains(top.path) { r.files -= top.files; r.bytes -= top.bytes; continue }
            for c in top.children where excluded.contains(c.path) { r.files -= c.files; r.bytes -= c.bytes }
        }
        return r
    }
}
