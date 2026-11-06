import Foundation
import os

/// When a long job (backup, check, cleanup) last showed it is alive, in system uptime, so the app can tell a job
/// that is slow from one that is stuck. Progress comes once per file: a big file copied to a slow disk beats
/// from inside the copy, or says beforehand how long it may take.
public enum Activity {
    private static let state = OSAllocatedUnfairLock(initialState: (at: ProcessInfo.processInfo.systemUptime, grace: 0.0))

    /// `grace`: how much longer than usual the step starting now may stay silent (a single big copy).
    public static func beat(grace: TimeInterval = 0) {
        let now = ProcessInfo.processInfo.systemUptime
        state.withLock { $0 = (now, grace) }
    }

    /// Seconds since the last beat, less the grace that beat asked for.
    public static var silence: TimeInterval {
        let s = state.withLock { $0 }
        return ProcessInfo.processInfo.systemUptime - s.at - s.grace
    }
}
