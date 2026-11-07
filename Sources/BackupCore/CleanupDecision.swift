import Foundation

/// What cleanup may do after a backup attempt.
public enum CleanupDecision: Equatable, Sendable {
    /// No cleanup at all.
    case skip
    /// Cleanup that never deletes these backups.
    case prune(pinned: Set<String>)
}

/// Decides cleanup after a backup attempt. `thrown`: the error the run stopped on, nil when it returned a report;
/// `lastComplete`: the newest backup with every source saved, nil when unknown or no longer in the archive.
public func cleanupDecision(thrown: Error?, report: BackupReport, lastComplete: String?) -> CleanupDecision {
    switch thrown {
    // stopped on purpose (or by the 2-hour timeout): cleanup would delete every object this run already copied
    // and make the next attempt start over
    case BackupError.cancelled?: return .skip
    // another process holds the archive (a check stuck on a read): cleanup would fail too and report a damaged archive
    case RepositoryError.locked?: return .skip
    default: break
    }
    // a partial backup (a source unreadable, deleted or renamed) must not let retention replace complete snapshots
    // with it: the last complete one is pinned, and without one there is no cleanup
    let partial = report.error != nil && report.snapshotID != nil
    if partial, lastComplete == nil { return .skip }
    // the backup just made too: with a clock gone wrong it may not look like the newest
    return .prune(pinned: Set([partial ? lastComplete : nil, report.snapshotID].compactMap { $0 }))
}
