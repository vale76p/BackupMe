import Foundation
import os

/// The system log (Console, `log stream`), subsystem com.vale76p.BackupMe. Info and errors always; Debug only
/// when chosen in Impostazioni › Avanzate, and Console shows it with Azione › Includi messaggi di debug.
enum Log {
    enum Level: String, CaseIterable { case info, debug }
    static let levelKey = "logLevel"
    static let subsystem = "com.vale76p.BackupMe"
    static var level: Level { Level(rawValue: UserDefaults.standard.string(forKey: levelKey) ?? "") ?? .info }

    static let app = Channel("app"), backup = Channel("backup"), restore = Channel("restore")

    struct Channel: Sendable {
        let logger: Logger
        init(_ category: String) { logger = Logger(subsystem: Log.subsystem, category: category) }

        func info(_ message: String) { logger.info("\(message, privacy: .public)") }
        func error(_ message: String) { logger.error("\(message, privacy: .public)") }
        /// Formatted only at Debug: the per-step details aren't free to build.
        func debug(_ message: @autoclosure () -> String) {
            guard Log.level == .debug else { return }
            let text = message()
            logger.debug("\(text, privacy: .public)")
        }
    }
}
