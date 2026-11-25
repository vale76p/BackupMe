import BackupCore
import Foundation

/// What the list shows of a folder: everything, or only what differs from this Mac's disk.
public enum ChangeFilter: String, CaseIterable, Sendable { case all, modified, missing, added }

/// A row against this Mac's disk; folders also say whether something inside them changed or disappeared.
public struct RowStatus: Equatable, Sendable {
    public var own: EntryStatus
    public var modifiedInside = false
    public var missingInside = false

    public init(own: EntryStatus, modifiedInside: Bool = false, missingInside: Bool = false) {
        self.own = own; self.modifiedInside = modifiedInside; self.missingInside = missingInside
    }

    /// Whether a row with this status passes a filter: a folder counts when something inside it changed or vanished.
    /// «Tutto» takes every row, and no row of the backup is «Nuovo»: those are today's files, kept apart.
    public func passes(_ filter: ChangeFilter) -> Bool {
        switch filter {
        case .all: true
        case .modified: own == .modified || modifiedInside
        case .missing: own == .missing || missingInside
        case .added: false
        }
    }
}
