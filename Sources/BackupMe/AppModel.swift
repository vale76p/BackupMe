import AppKit
import BackupCore
import Foundation
import os

enum BackupStatus: Equatable { case idle, running(Double), failed(String) }

@MainActor @Observable final class AppModel {
    var settings = AppSettings.load() {
        didSet {
            settings.save()
            if settings.isConfigured, configuredSince == nil { configuredSince = Date() }
            // this error is about the settings, not a backup: it goes away as soon as they are complete
            if settings.isConfigured, status == .failed(Self.notConfigured) { status = .idle }
        }
    }
    static let notConfigured = "Scegli cartelle e destinazione nelle Impostazioni"
    var status: BackupStatus = .idle
    var history: [BackupReport] = []
    var notificationsDenied = false

    // stored apart from history: 50 failed retries would otherwise push it out and silence the 3-day alert
    var lastSuccess = UserDefaults.standard.object(forKey: "lastSuccess") as? Date {
        didSet { UserDefaults.standard.set(lastSuccess, forKey: "lastSuccess") }
    }
    private var configuredSince = UserDefaults.standard.object(forKey: "configuredSince") as? Date {
        didSet { UserDefaults.standard.set(configuredSince, forKey: "configuredSince") }
    }
    private var overCapNotified = UserDefaults.standard.bool(forKey: "overCapNotified") {
        didSet { UserDefaults.standard.set(overCapNotified, forKey: "overCapNotified") }
    }
    /// Newest backup with every source saved: cleanup after a partial backup must never delete it.
    private var lastComplete = UserDefaults.standard.string(forKey: "lastCompleteSnapshot") {
        didSet { UserDefaults.standard.set(lastComplete, forKey: "lastCompleteSnapshot") }
    }
    /// True until the backup task really ends: after a "stuck" timeout it may still hold the archive lock.
    private var workerActive = false
    var isRunning: Bool { if case .running = status { true } else { false } }
    var lastReport: BackupReport? { history.last }

    private var cancelFlag = OSAllocatedUnfairLock(initialState: false)
    private var lastAttempt: Date?
    private var lastProgressAt = Date()
    private var lastStaleNotice: Date?
    private var notifiedErrors = Set<String>()
    private var timer: Timer?
    private let log = Logger(subsystem: "com.vale76p.BackupMe", category: "backup")

    static let retryAfterFailure: TimeInterval = 15 * 60
    static let staleAfter: TimeInterval = 3 * 86400
    static let stuckAfter: TimeInterval = 2 * 3600

    init() {
        SystemServices.quitIfAlreadyRunning()
        if let data = try? Data(contentsOf: AppPaths.history) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
            history = (try? dec.decode([BackupReport].self, from: data)) ?? []
        }
        if settings.isConfigured, configuredSince == nil { configuredSince = Date() }
        if !UserDefaults.standard.bool(forKey: "loginAgentConfigured") {
            // a backup service should run without being opened by hand: on by default
            try? SystemServices.setLaunchAtLogin(true)
            UserDefaults.standard.set(true, forKey: "loginAgentConfigured")
        }
        // asked in context: the first-run window asks when the first backup starts
        if settings.isConfigured { SystemServices.requestNotificationPermission() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            // give network and OneDrive a minute after wake
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { MainActor.assumeIsolated { self.tick() } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { MainActor.assumeIsolated { self.tick() } }
    }

    /// Opens an existing archive for browsing; never creates one.
    func repository(computer: String? = nil) throws -> Repository {
        guard let dest = settings.destination else { throw RepositoryError.destinationMissing("") }
        return try Repository(destination: URL(fileURLWithPath: dest), computerName: computer ?? AppPaths.archiveName, create: false)
    }

    func tick(now: Date = Date()) {
        Task { notificationsDenied = !(await SystemServices.notificationsAllowed()) }
        if isRunning, now.timeIntervalSince(lastProgressAt) > Self.stuckAfter {
            // a read blocked forever (offline OneDrive file, hung volume) must not stop every later backup
            cancelBackup()
            fail("Backup bloccato da più di 2 ore: riparte appena si sblocca, o riavvia BackupMe")
        }
        // stale since the last success, or since setup if none ever succeeded; a future date means a wrong clock
        if settings.isConfigured, let since = lastSuccess ?? configuredSince,
           now.timeIntervalSince(since) > Self.staleAfter || since > now.addingTimeInterval(86400),
           lastStaleNotice.map({ now.timeIntervalSince($0) > 86400 }) ?? true {
            lastStaleNotice = now
            SystemServices.notify("BackupMe", "Nessun backup riuscito da più di 3 giorni.")
        }
        guard !settings.paused, settings.isConfigured, !isRunning,
              isBackupDue(lastSuccess: lastSuccess, intervalHours: settings.intervalHours, now: now),
              lastAttempt.map({ now.timeIntervalSince($0) >= Self.retryAfterFailure || $0 > now }) ?? true else { return }
        backupNow()
    }

    func backupNow() {
        guard !isRunning, !workerActive else { return }
        guard settings.isConfigured else {
            status = .failed(Self.notConfigured)
            return
        }
        lastAttempt = Date()
        lastProgressAt = Date()
        status = .running(0)
        let flag = OSAllocatedUnfairLock(initialState: false)
        cancelFlag = flag
        let s = settings
        let archive = AppPaths.archiveName
        let complete = lastComplete
        workerActive = true
        Task.detached(priority: .utility) {
            // a long first backup must not stop at every idle sleep; also keeps App Nap away
            let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
                                                                 reason: "Backup in corso")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            var lastSent = 0.0
            let (report, overCap) = Self.perform(settings: s, archive: archive, lastComplete: complete,
                                                 isCancelled: { flag.withLock { $0 } }) { p in
                guard p - lastSent >= 0.01 || p == 1 else { return }
                lastSent = p
                Task { @MainActor in
                    self.lastProgressAt = Date()
                    if self.isRunning { self.status = .running(p) }
                }
            }
            await MainActor.run {
                self.workerActive = false
                self.finish(report, overCap: overCap)
            }
        }
    }

    func cancelBackup() { cancelFlag.withLock { $0 = true } }

    nonisolated static func perform(settings s: AppSettings, archive: String, lastComplete: String?, isCancelled: @escaping () -> Bool,
                                    progress: @escaping (Double) -> Void) -> (BackupReport, Bool?) {
        let start = Date()
        func failed(_ error: Error) -> BackupReport {
            BackupReport(snapshotID: nil, date: start, duration: Date().timeIntervalSince(start), fileCount: 0,
                         newBytes: 0, warnings: [], error: describe(error))
        }
        let repo: Repository
        do {
            repo = try Repository(destination: URL(fileURLWithPath: s.destination ?? ""), computerName: archive)
        } catch {
            return (failed(error), nil)
        }
        var report: BackupReport
        do {
            let engine = BackupEngine(repository: repo, cache: HashCache(url: AppPaths.hashCache(archive)),
                                      excludes: ExcludeRules(patterns: s.excludes))
            report = try engine.run(sources: s.sources.map { URL(fileURLWithPath: $0) }, now: start,
                                    progress: progress, isCancelled: isCancelled)
        } catch {
            report = failed(error)
        }
        // a partial backup (a source unreadable, deleted or renamed) must not let retention replace complete
        // snapshots with it: the last complete one is pinned. Unknown or not in this archive: skip cleanup.
        let partial = report.error != nil && report.snapshotID != nil
        let pin = partial ? lastComplete.flatMap { repo.snapshotExists($0) ? $0 : nil } : nil
        guard !partial || pin != nil else { return (report, nil) }
        do {
            // clamp: Int64(x * 1e9) traps above ~9.2e9 GB
            let cap = s.capGB.map { Int64(min($0, 1_000_000) * 1e9) }
            // a failed run may have left orphan objects: collect them (this also frees space when the disk is full)
            let result = try prune(repository: repo, policy: s.retention, capBytes: cap, now: Date(),
                                   refsCache: AppPaths.refsCache(archive, destination: repo.root.path), forceGC: report.snapshotID == nil,
                                   pinned: pin.map { [$0] } ?? [])
            if result.gcSkipped { report.warnings.append("Pulizia rinviata: alcuni backup sono spariti dalla destinazione, riprende da sola entro 3 giorni") }
            return (report, result.overCap)
        } catch {
            report.warnings.append("Pulizia non riuscita: \(describe(error))")
            return (report, nil)
        }
    }

    private func finish(_ report: BackupReport, overCap: Bool?) {
        history.append(report)
        if history.count > 50 { history.removeFirst(history.count - 50) }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        try? enc.encode(history).write(to: AppPaths.history, options: .atomic)

        if report.error == nil, let id = report.snapshotID { lastComplete = id }
        if let err = report.error {
            fail(err)
        } else {
            status = .idle
            lastAttempt = nil
            lastSuccess = report.date
            notifiedErrors = []
            log.info("backup \(report.snapshotID ?? "", privacy: .public): \(report.fileCount) files, \(report.newBytes) new bytes, \(report.warnings.count) warnings")
        }
        if let pruneWarning = report.warnings.last(where: { $0.hasPrefix("Pulizia non riuscita") }) { notifyOnce(pruneWarning) }
        if let overCap, overCap != overCapNotified {
            overCapNotified = overCap
            if overCap { SystemServices.notify("BackupMe", "Il tetto è troppo basso per le cartelle selezionate.") }
        }
    }

    private func fail(_ message: String) {
        status = .failed(message)
        log.error("backup failed: \(message, privacy: .public)")
        if message != Self.describe(BackupError.cancelled) { notifyOnce(message) }
    }

    /// One notification per distinct problem until the next successful backup.
    private func notifyOnce(_ message: String) {
        guard notifiedErrors.insert(message).inserted else { return }
        SystemServices.notify("Backup non riuscito", message)
    }

    nonisolated static func describe(_ error: Error) -> String {
        switch error {
        case RepositoryError.destinationMissing(let p): return "Destinazione non trovata: \(p)"
        case RepositoryError.locked: return "Un altro backup è già in corso"
        case RepositoryError.corruptObject(let h): return "Archivio danneggiato (oggetto \(h.prefix(12)))"
        case BackupError.sourceOverlapsDestination(let p): return "La cartella \(p) contiene la destinazione o è al suo interno"
        case BackupError.cancelled: return "Backup interrotto"
        case RestoreError.notFound(let p): return "\(p.isEmpty ? "La cartella" : p) non è in questo backup"
        case RestoreError.invalidEntry(let p): return "Backup non valido o manomesso (percorso \"\(p)\"): ripristino annullato"
        case RestoreError.keptBeside(let p):
            return "Non è stato possibile sostituire: l'originale è nel Cestino e la versione ripristinata è in \(p)"
        default: return error.localizedDescription
        }
    }
}
