import Foundation

public struct ExcludeRules: Sendable {
    public static let defaults = ["node_modules", ".build", "DerivedData", "build", "dist", ".venv", "venv",
                                  "__pycache__", ".DS_Store", "Pods", ".gradle", "target"]
    public let patterns: [String]

    public init(patterns: [String]) {
        self.patterns = patterns.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public func excludes(name: String) -> Bool {
        patterns.contains { fnmatch($0, name, 0) == 0 }
    }
}
