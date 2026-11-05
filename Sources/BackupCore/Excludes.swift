import Foundation

public struct ExcludeRules: Sendable {
    public static let defaults = ["node_modules", ".build", "DerivedData", "build", "dist", ".venv", "venv",
                                  "__pycache__", ".DS_Store", "Pods", ".gradle", "target"]
    public let patterns: [String]

    public init(patterns: [String]) {
        self.patterns = patterns.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// A pattern always matches folders. It matches files only if it has a wildcard (`*.log`) or starts
    /// with a dot (`.DS_Store`): a script named `build` or a file named `dist` is not a build folder.
    public func excludes(name: String, isDirectory: Bool) -> Bool {
        patterns.contains { p in
            (isDirectory || p.hasPrefix(".") || p.contains(where: { "*?[".contains($0) })) && fnmatch(p, name, 0) == 0
        }
    }
}
