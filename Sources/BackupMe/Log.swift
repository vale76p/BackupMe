import Foundation
import os

/// The system log (Console, `log stream`), subsystem com.vale76p.BackupMe. Info and errors always; Debug only
/// when chosen in Impostazioni › Avanzate, and Console shows it with Azione › Includi messaggi di debug.
/// Every line is also appended to `file`, which Impostazioni › Registro shows: it survives restarts and crashes.
enum Log {
    enum Level: String, CaseIterable { case info, debug }
    static let levelKey = "logLevel"
    static let subsystem = "com.vale76p.BackupMe"
    static var level: Level { Level(rawValue: UserDefaults.standard.string(forKey: levelKey) ?? "") ?? .info }

    static let app = Channel("app"), backup = Channel("backup"), restore = Channel("restore")

    static let file = AppPaths.support.appending(path: "BackupMe.log")
    /// The file before the last rotation.
    static let previousFile = file.appendingPathExtension("1")
    private static let queue = DispatchQueue(label: "com.vale76p.BackupMe.log")
    private static let rotateAt = 1_000_000

    fileprivate static func append(_ level: String, _ category: String, _ message: String) {
        let line = "\(Date().formatted(date: .numeric, time: .standard)) \(level) [\(category)] \(message)\n"
        queue.async {
            let fm = FileManager.default
            if let size = try? fm.attributesOfItem(atPath: file.path)[.size] as? Int, size > rotateAt {
                try? fm.removeItem(at: previousFile)
                try? fm.moveItem(at: file, to: previousFile)
            }
            if let h = try? FileHandle(forWritingTo: file) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: Data(line.utf8))
                try? h.close()
            } else {
                try? Data(line.utf8).write(to: file)
            }
        }
    }

    /// The last lines, oldest first, the rotated file included when the current one is short.
    static func lines(limit: Int = 2000) -> [String] {
        queue.sync {
            let read = { (url: URL) in (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? [] }
            var all = read(file)
            if all.count < limit { all = read(previousFile) + all }
            return Array(all.suffix(limit))
        }
    }

    static func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: previousFile)
        }
    }

    struct Channel: Sendable {
        let logger: Logger

        let category: String
        init(_ category: String) {
            self.category = category
            logger = Logger(subsystem: Log.subsystem, category: category)
        }

        func info(_ message: String) { logger.info("\(message, privacy: .public)"); Log.append("INFO ", category, message) }
        func error(_ message: String) { logger.error("\(message, privacy: .public)"); Log.append("ERROR", category, message) }
        /// Formatted only at Debug: the per-step details aren't free to build.
        func debug(_ message: @autoclosure () -> String) {
            guard Log.level == .debug else { return }
            let text = message()
            logger.debug("\(text, privacy: .public)")
            Log.append("DEBUG", category, text)
        }
    }
}
