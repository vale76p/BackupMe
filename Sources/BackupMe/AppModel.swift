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
            // set up from Impostazioni (not the first-run window): errors must still be able to reach the user
            if settings.isConfigured, !oldValue.isConfigured { SystemServices.requestNotificationPermission() }
            // a new destination starts empty: back up there now rather than up to a whole interval later
            if settings.isConfigured, oldValue.destination != nil, settings.destination != oldValue.destination { backupNow() }
        }
    }
    static let notConfigured = "Scegli cartelle e destinazione nelle Impostazioni"
    nonisolated static let damaged = "Archivio danneggiato:"
    nonisolated static let incomplete = "Archivio incompleto:"
    var status: BackupStatus = .idle
    var history: [BackupReport] = []
    var notificationsDenied = false
    /// Why the scheduled backup is waiting right now (battery, heat), shown in the panel.
    var deferral: SystemServices.Deferral?
    /// The cloud client isn't uploading the backups (paused, signed out, blocked): they exist only on this Mac.
    var uploadProblem: String?
    private var lastUploadCheck: Date?
    private var lastUploadNotice: Date?

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
    private var lastVerify = UserDefaults.standard.object(forKey: "lastVerify") as? Date {
        didSet { UserDefaults.standard.set(lastVerify, forKey: "lastVerify") }
    }
    var isRunning: Bool { if case .running = status { true } else { false } }
    var lastReport: BackupReport? { history.last }

    private var cancelFlag = OSAllocatedUnfairLock(initialState: false)
    private var lastAttempt: Date?
    /// Uptime, not wall time: a lid closed for hours during a backup must not look like a stuck read.
    private var lastProgressUptime = ProcessInfo.processInfo.systemUptime
    private var lastStaleNotice: Date?
    private var notifiedErrors = Set<String>()
    private var timer: Timer?

    static let retryAfterFailure: TimeInterval = 15 * 60
    static let staleAfter: TimeInterval = 3 * 86400
    static let stuckAfter: TimeInterval = 2 * 3600

    init() {
        SystemServices.quitIfAlreadyRunning()
        if let data = try? Data(contentsOf: AppPaths.history) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
            if let saved = try? dec.decode([BackupReport].self, from: data) { history = saved } else {
                // kept aside, like unreadable settings: the next backup would overwrite it
                try? FileManager.default.removeItem(at: AppPaths.history.appendingPathExtension("illeggibile"))
                try? FileManager.default.moveItem(at: AppPaths.history, to: AppPaths.history.appendingPathExtension("illeggibile"))
            }
        }
        if settings.isConfigured, configuredSince == nil { configuredSince = Date() }
        if !UserDefaults.standard.bool(forKey: "loginAgentConfigured") {
            // a backup service should run without being opened by hand: on by default
            try? SystemServices.setLaunchAtLogin(true)
            UserDefaults.standard.set(true, forKey: "loginAgentConfigured")
        }
        // asked in context: the first-run window asks when the first backup starts
        if settings.isConfigured { SystemServices.requestNotificationPermission() }
        SystemServices.repairLaunchAgent()
        // common modes: in the default mode it doesn't fire while an open panel or a menu is up
        let timer = Timer(timeInterval: 60, repeats: true) { _ in MainActor.assumeIsolated { self.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
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
        if lastUploadCheck.map({ now.timeIntervalSince($0) > 3600 || $0 > now }) ?? true {
            lastUploadCheck = now
            checkUpload()
        }
        if isRunning, ProcessInfo.processInfo.systemUptime - lastProgressUptime > Self.stuckAfter {
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
              lastAttempt.map({ now.timeIntervalSince($0) >= Self.retryAfterFailure || $0 > now }) ?? true else {
            deferral = nil
            return
        }
        // waits for power or a cooler Mac, but never past a day without a backup; "Esegui ora" always runs
        let overdue = lastSuccess.map { now.timeIntervalSince($0) > 86400 } ?? true
        let reason = overdue ? nil : SystemServices.backupDeferral()
        if reason != deferral, let reason { Log.backup.info("Backup pianificato rinviato: \(reason.reason)") }
        deferral = reason
        guard deferral == nil else { return }
        backupNow()
    }

    func backupNow() {
        guard !isRunning, !workerActive else { return }
        guard settings.isConfigured else {
            status = .failed(Self.notConfigured)
            return
        }
        lastAttempt = Date()
        lastProgressUptime = ProcessInfo.processInfo.systemUptime
        status = .running(0)
        let flag = OSAllocatedUnfairLock(initialState: false)
        cancelFlag = flag
        let s = settings
        let archive = AppPaths.archiveName
        let complete = lastComplete
        let verify = lastVerify.map { Date().timeIntervalSince($0) > 86400 || $0 > Date() } ?? true
        Log.backup.info("Avvio backup di \(s.sources.count) cartelle in \(s.destination ?? "")")
        Log.backup.debug("Cartelle: \(s.sources.joined(separator: ", ")); esclusioni: \(s.excludes.joined(separator: " ")); verifica a campione: \(verify ? "sì" : "no")")
        workerActive = true
        Task.detached(priority: .utility) {
            // a long first backup must not stop at every idle sleep; also keeps App Nap away
            let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
                                                                 reason: "Backup in corso")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            var lastSent = 0.0
            let (report, overCap, verified) = Self.perform(settings: s, archive: archive, lastComplete: complete, verify: verify,
                                                 isCancelled: { flag.withLock { $0 } }) { p in
                guard p - lastSent >= 0.01 || p == 1 else { return }
                lastSent = p
                Task { @MainActor in
                    self.lastProgressUptime = ProcessInfo.processInfo.systemUptime
                    if self.isRunning { self.status = .running(p) }
                }
            }
            await MainActor.run {
                self.workerActive = false
                if verified { self.lastVerify = Date() } // not when the archive couldn't even be opened
                self.finish(report, overCap: overCap)
            }
        }
    }

    func cancelBackup() { cancelFlag.withLock { $0 = true } }

    private func checkUpload() {
        guard let dest = settings.destination else { uploadProblem = nil; return }
        let archive = AppPaths.archiveName
        Task.detached(priority: .utility) {
            let problem = Self.uploadProblem(destination: dest, archive: archive, now: Date())
            Log.backup.debug("Controllo caricamento nel cloud: \(problem ?? "nessun problema")")
            await MainActor.run {
                self.uploadProblem = problem
                if let problem, self.lastUploadNotice.map({ Date().timeIntervalSince($0) > 86400 }) ?? true {
                    self.lastUploadNotice = Date()
                    SystemServices.notify("Backup non caricati nel cloud", problem)
                }
            }
        }
    }

    /// Reads the manifests' cloud status, newest first. nil when all is well, and also when the folder isn't
    /// synced or its client doesn't report upload state: then there is nothing reliable to say.
    nonisolated static func uploadProblem(destination: String, archive: String, now: Date) -> String? {
        guard let repo = try? Repository(destination: URL(fileURLWithPath: destination), computerName: archive, create: false),
              let ids = try? repo.snapshotIDs(), let newest = ids.last else { return nil }
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemUploadingErrorKey]
        let stale: TimeInterval = 3 * 86400
        for id in ids.reversed() {
            // archive layout (README): snapshots/<id>.json.lzfse
            let url = repo.root.appending(path: "snapshots/\(id).json.lzfse")
            guard let v = try? url.resourceValues(forKeys: keys), v.isUbiquitousItem == true,
                  let uploaded = v.ubiquitousItemIsUploaded else { return nil }
            if let err = v.ubiquitousItemUploadingError { return "Il caricamento non riesce: \(err.localizedDescription)" }
            guard uploaded else { continue }
            // the newest uploaded backup: a problem only when newer ones have waited for days
            guard id != newest, let date = Snapshot.date(fromID: id), now.timeIntervalSince(date) > stale else { return nil }
            return "L'ultimo backup caricato nel cloud è del \(date.formatted(date: .abbreviated, time: .shortened))"
        }
        guard let oldest = ids.first.flatMap(Snapshot.date(fromID:)), now.timeIntervalSince(oldest) > stale else { return nil }
        return "Nessun backup è ancora stato caricato nel cloud"
    }

    nonisolated static func perform(settings s: AppSettings, archive: String, lastComplete: String?, verify: Bool,
                                    isCancelled: @escaping () -> Bool,
                                    progress: @escaping (Double) -> Void) -> (BackupReport, Bool?, Bool) {
        let start = Date()
        func failed(_ error: Error) -> BackupReport {
            BackupReport(snapshotID: nil, date: start, duration: Date().timeIntervalSince(start), fileCount: 0,
                         newBytes: 0, warnings: [], error: describe(error))
        }
        let repo: Repository
        do {
            repo = try Repository(destination: URL(fileURLWithPath: s.destination ?? ""), computerName: archive)
        } catch {
            return (failed(error), nil, false)
        }
        var report: BackupReport
        let cache = HashCache(url: AppPaths.hashCache(archive))
        do {
            let engine = BackupEngine(repository: repo, cache: cache, excludes: ExcludeRules(patterns: s.excludes))
            report = try engine.run(sources: s.sources.map { URL(fileURLWithPath: $0) }, now: start,
                                    progress: progress, isCancelled: isCancelled)
        } catch {
            report = failed(error)
        }
        Log.backup.debug("Scansione: \(report.fileCount) file, \(report.newBytes) byte nuovi, \(report.excluded?.count ?? 0) cartelle escluse, manifest \(report.snapshotID ?? "nessuno")\(report.warnings.isEmpty ? "" : "; avvisi: " + report.warnings.joined(separator: " | "))")
        // once a day a sample of the archive is read back: a copy damaged by a sync conflict shows up now, not
        // at restore time. Small budget: on OneDrive Files On-Demand every read may be a download.
        var verified = false
        if verify, !isCancelled() {
            do {
                let v = try verifySample(repository: repo, cache: cache, budgetBytes: 100_000_000)
                verified = true
                Log.backup.debug("Verifica a campione: \(v.checked) oggetti, \(v.bytes) byte, \(v.repaired.count) riparati, \(v.corrupt.count) danneggiati")
                if !v.repaired.isEmpty {
                    report.warnings.append(v.repaired.count == 1 ? "Riparato 1 file danneggiato nell'archivio usando la copia attuale"
                                           : "Riparati \(v.repaired.count) file danneggiati nell'archivio usando le copie attuali")
                }
                if !v.corrupt.isEmpty {
                    report.warnings.append("\(Self.damaged) \(v.corrupt.count) file non si possono leggere e manca una copia attuale per ripararli: i backup che li usano non si ripristinano per intero")
                }
            } catch {
                report.warnings.append("Verifica dell'archivio non riuscita: \(describe(error))")
            }
        }
        // a partial backup (a source unreadable, deleted or renamed) must not let retention replace complete
        // snapshots with it: the last complete one is pinned. Unknown or not in this archive: skip cleanup.
        let partial = report.error != nil && report.snapshotID != nil
        let pin = partial ? lastComplete.flatMap { repo.snapshotExists($0) ? $0 : nil } : nil
        guard !partial || pin != nil else { return (report, nil, verified) }
        do {
            // clamp: Int64(x * 1e9) traps above ~9.2e9 GB
            let cap = s.capGB.map { Int64(min($0, 1_000_000) * 1e9) }
            // a failed run may have left orphan objects: collect them (this also frees space when the disk is full)
            let result = try prune(repository: repo, policy: s.retention, capBytes: cap, now: Date(),
                                   refsCache: AppPaths.refsCache(archive, destination: repo.root.path), forceGC: report.snapshotID == nil,
                                   // the backup just made too: with a clock gone wrong it may not look like the newest
                                   pinned: Set([pin, report.snapshotID].compactMap { $0 }))
            Log.backup.debug("Pulizia: \(result.deletedSnapshots.count) backup e \(result.deletedObjects) oggetti eliminati, archivio \(result.poolSize) byte, oltre il tetto: \(result.overCap), rinviata: \(result.gcSkipped), oggetti mancanti: \(result.missingObjects)")
            if result.gcSkipped { report.warnings.append("Pulizia rinviata: alcuni backup sono spariti dalla destinazione, riprende da sola entro 3 giorni") }
            if result.missingObjects > 0 {
                report.warnings.append("\(Self.incomplete) mancano \(result.missingObjects) file usati dai backup, che non si ripristinano per intero")
            }
            return (report, result.overCap, verified)
        } catch {
            report.warnings.append("Pulizia non riuscita: \(describe(error))")
            return (report, nil, verified)
        }
    }

    private func finish(_ report: BackupReport, overCap: Bool?) {
        history.append(report)
        if history.count > 50 { history.removeFirst(history.count - 50) }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        try? enc.encode(history).write(to: AppPaths.history, options: .atomic)

        if report.error == nil, let id = report.snapshotID { lastComplete = id }
        // "Interrompi" must not be followed by a new backup a minute later: retry as after a failure
        if report.error == Self.describe(BackupError.cancelled) { lastAttempt = Date() }
        if let err = report.error {
            fail(err)
        } else {
            status = .idle
            lastAttempt = nil
            lastSuccess = report.date
            notifiedErrors = []
            Log.backup.info("Backup \(report.snapshotID ?? "") riuscito: \(report.fileCount) file, \(report.newBytes) byte nuovi, \(report.warnings.count) avvisi, \(Int(report.duration)) s")
        }
        // warnings that mean a backup can't be fully restored are notified, not just listed
        for w in report.warnings where [Self.damaged, Self.incomplete, "Pulizia non riuscita"].contains(where: w.hasPrefix) { notifyOnce(w) }
        if let overCap, overCap != overCapNotified {
            overCapNotified = overCap
            if overCap { SystemServices.notify("BackupMe", "Il tetto è troppo basso per le cartelle selezionate.") }
        }
    }

    private func fail(_ message: String) {
        status = .failed(message)
        Log.backup.error("Backup non riuscito: \(message)")
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
