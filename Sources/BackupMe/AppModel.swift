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
    nonisolated static let damaged = BackupEngine.damagedPrefix
    nonisolated static let incomplete = "Archivio incompleto:"
    nonisolated static let recreated = "Archivio ricreato:"
    static let criticalPrefixes = [damaged, incomplete, recreated, "Pulizia non riuscita"]
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
    /// The same for the full check, which holds the lock too.
    private var checkWorkerActive = false
    /// The deletion of damaged backups, which holds the lock: a backup waits for it, never "stuck".
    private var deleting = false
    /// Bumped when a deletion of damaged backups ends: what the archive holds and takes changed.
    private(set) var deletions = 0
    /// The last archive problem (damaged, incomplete, recreated, cleanup failed): it stays in the badge until a
    /// full check finds the archive healthy, not only for the one backup that noticed it.
    var archiveProblem = UserDefaults.standard.string(forKey: "archiveProblem") {
        didSet { UserDefaults.standard.set(archiveProblem, forKey: "archiveProblem") }
    }
    private var lastVerify = UserDefaults.standard.object(forKey: "lastVerify") as? Date {
        didSet { UserDefaults.standard.set(lastVerify, forKey: "lastVerify") }
    }
    /// Progress of the full archive check, nil when none is running; backups wait until it ends.
    var checkProgress: Double?
    /// Kept here, not in the Sfoglia window: closing the window must not allow a second restore at the same time.
    var restoring = false {
        didSet { if !restoring, deferral == Self.restoreDeferral { deferral = nil } }
    }
    static let restoreDeferral = SystemServices.Deferral(reason: "Ripristino in corso", until: "Alla fine del ripristino")
    static let stuckCheckDeferral = SystemServices.Deferral(reason: "Controllo dell'archivio bloccato",
                                                            until: "Quando si sblocca, o riavvia BackupMe")
    static let deletingDeferral = SystemServices.Deferral(reason: "Eliminazione dei backup illeggibili in corso",
                                                          until: "Alla fine dell'eliminazione")
    /// Why no backup can start now even by hand: a check stuck on a read still holds the lock, or a restore runs
    /// (cleanup could delete the backup being restored).
    private var blockedDeferral: SystemServices.Deferral? {
        deleting ? Self.deletingDeferral : checkWorkerActive ? Self.stuckCheckDeferral : restoring ? Self.restoreDeferral : nil
    }
    /// The last full check's outcome, in words, and whether the archive was healthy.
    var checkResult: (text: String, healthy: Bool)?
    /// Backups the last full check couldn't read, which Impostazioni › Avanzate offers to delete.
    var damagedBackups: [String] = []
    /// Whether the last full check found anything besides those backups.
    private var otherCheckProblems = false
    private var checkCancel = OSAllocatedUnfairLock(initialState: false)
    private var lastCheckProgressUptime = ProcessInfo.processInfo.systemUptime
    var isRunning: Bool { if case .running = status { true } else { false } }
    var lastReport: BackupReport? { history.last }

    private var cancelFlag = OSAllocatedUnfairLock(initialState: false)
    private var lastAttempt: Date?
    /// Uptime, not wall time: a lid closed for hours during a backup must not look like a stuck read.
    private var lastProgressUptime = ProcessInfo.processInfo.systemUptime
    private var lastStaleNotice: Date?
    private var notifiedErrors = Set<String>()
    private var timer: Timer?
    /// Uptime of the last wake: scheduled backups wait a minute after it.
    private var wokeAt: TimeInterval = -.infinity
    private var uploadCheckRunning = false
    /// The login agent pointed at a moved or old copy of the app and was rewritten at this launch.
    private var launchAgentRepaired = false

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
        // the last attempt's failure, still unsolved: the icon must not turn green just because the app restarted
        if let err = lastReport?.error, err != Self.describe(BackupError.cancelled) { status = .failed(err) }
        if settings.isConfigured, configuredSince == nil { configuredSince = Date() }
        if !UserDefaults.standard.bool(forKey: "loginAgentConfigured") {
            // a backup service should run without being opened by hand: on by default
            try? SystemServices.setLaunchAtLogin(true)
            UserDefaults.standard.set(true, forKey: "loginAgentConfigured")
        }
        // asked in context: the first-run window asks when the first backup starts
        if settings.isConfigured { SystemServices.requestNotificationPermission() }
        launchAgentRepaired = SystemServices.repairLaunchAgent()
        _ = SystemServices.network
        // common modes: in the default mode it doesn't fire while an open panel or a menu is up
        let timer = Timer(timeInterval: 60, repeats: true) { _ in MainActor.assumeIsolated { self.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            // give network and OneDrive a minute after wake: the 60 s timer may fire seconds after it
            MainActor.assumeIsolated { self.wokeAt = ProcessInfo.processInfo.systemUptime }
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
        // stuck only when neither progress nor the engine's own heartbeat (big copies, scan, cleanup) moved
        if isRunning, min(ProcessInfo.processInfo.systemUptime - lastProgressUptime, Activity.silence) > Self.stuckAfter {
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
        if checkProgress != nil {
            if min(ProcessInfo.processInfo.systemUptime - lastCheckProgressUptime, Activity.silence) > Self.stuckAfter {
                // a read blocked in the check must not stop the backups for good
                cancelCheck()
                checkProgress = nil
                checkResult = ("Controllo bloccato da più di 2 ore: interrotto, i backup riprendono appena si sblocca, o riavvia BackupMe", false)
                Log.backup.error("Controllo completo dell'archivio bloccato da più di 2 ore: interrotto")
            } else {
                // said in the panel instead of skipping the backup in silence
                deferral = SystemServices.Deferral(reason: "Controllo dell'archivio in corso", until: "Alla fine del controllo")
                return
            }
        }
        // said in the panel and in "Prossimo backup", whether a backup is due or not, instead of nothing happening
        if let blocked = blockedDeferral, !isRunning, !settings.paused, settings.isConfigured { deferral = blocked; return }
        guard !settings.paused, settings.isConfigured, !isRunning,
              isBackupDue(lastSuccess: lastSuccess, intervalHours: settings.intervalHours, now: now),
              lastAttempt.map({ now.timeIntervalSince($0) >= Self.retryAfterFailure || $0 > now }) ?? true else {
            deferral = nil
            return
        }
        guard ProcessInfo.processInfo.systemUptime - wokeAt >= 60 else { return }
        // waits for power or a cooler Mac, but never past a day without a backup; "Esegui ora" always runs
        let overdue = lastSuccess.map { now.timeIntervalSince($0) > 86400 } ?? true
        let reason = overdue ? nil : SystemServices.backupDeferral(onlyOnPower: settings.onlyOnPower, avoidMetered: settings.deferOnMetered)
        if reason != deferral, let reason { Log.backup.info("Backup pianificato rinviato: \(reason.reason)") }
        deferral = reason
        guard deferral == nil else { return }
        backupNow()
    }

    func backupNow() {
        guard !isRunning, !workerActive, checkProgress == nil else { return }
        // "Esegui ora" or "Riprova" must not do nothing in silence
        if let blocked = blockedDeferral { deferral = blocked; return }
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
        Log.backup.debug("Cartelle: \(s.sources.joined(separator: ", ")); esclusioni: \(s.excludes.joined(separator: " ")) \(s.excludeRules.paths.sorted().joined(separator: " ")); verifica a campione: \(verify ? "sì" : "no")")
        workerActive = true
        Task.detached(priority: .utility) {
            // a long first backup must not stop at every idle sleep; also keeps App Nap away
            let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
                                                                 reason: "Backup in corso")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            var lastSent = 0.0
            let (report, overCap, verified, upgrade) = Self.perform(settings: s, archive: archive, lastComplete: complete, verify: verify,
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
                if let upgrade { self.reportUpgrade(upgrade) } // after the backup: its Controlla ora can start now
                // the destination changed meanwhile: its own first backup was refused while this one ran
                if self.settings.destination != s.destination { self.backupNow() }
            }
        }
    }

    func cancelBackup() { cancelFlag.withLock { $0 = true } }

    /// Reads back every backup and every file of this Mac's archive, from Impostazioni › Avanzate.
    /// false when it couldn't start (a backup, a check or a deletion running, no destination).
    @discardableResult
    func checkArchiveNow() -> Bool {
        guard !isRunning, !workerActive, !checkWorkerActive, !deleting, checkProgress == nil, let dest = settings.destination else { return false }
        checkProgress = 0
        checkWorkerActive = true
        checkResult = nil
        damagedBackups = []
        deferral = nil
        lastCheckProgressUptime = ProcessInfo.processInfo.systemUptime
        let flag = OSAllocatedUnfairLock(initialState: false)
        checkCancel = flag
        let archive = AppPaths.archiveName
        Log.backup.info("Controllo completo dell'archivio avviato")
        Task.detached(priority: .utility) {
            // like a backup: hours on a cloud folder must not stop at every idle sleep
            let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "Controllo dell'archivio")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            var lastSent = 0.0
            let result = Result {
                let repo = try Repository(destination: URL(fileURLWithPath: dest), computerName: archive, create: false)
                return try checkArchive(repository: repo, cache: HashCache(url: AppPaths.hashCache(archive)),
                                        isCancelled: { flag.withLock { $0 } }) { p in
                    guard p - lastSent >= 0.01 || p == 1 else { return }
                    lastSent = p
                    Task { @MainActor in
                        self.lastCheckProgressUptime = ProcessInfo.processInfo.systemUptime
                        if self.checkProgress != nil { self.checkProgress = p }
                    }
                }
            }
            await MainActor.run {
                self.checkWorkerActive = false
                self.checkProgress = nil
                self.deferral = nil
                self.finishCheck(result)
                if self.settings.destination != dest { self.backupNow() }
            }
        }
        return true
    }

    func cancelCheck() { checkCancel.withLock { $0 = true } }

    private func finishCheck(_ result: Result<ArchiveCheck, Error>) {
        switch result {
        case .failure(BackupError.cancelled):
            checkResult = ("Controllo interrotto", false)
            Log.backup.info("Controllo completo dell'archivio interrotto")
        case .failure(let error):
            let text = "Controllo non riuscito: \(Self.describe(error))"
            checkResult = (text, false)
            Log.backup.error(text)
        case .success(let c):
            lastVerify = Date()
            let size = c.objects.bytes.formatted(.byteCount(style: .file))
            var problems: [String] = []
            if !c.unreadableSnapshots.isEmpty { problems.append("\(c.unreadableSnapshots.count) backup illeggibili, che non si possono ripristinare") }
            if c.missingObjects > 0 { problems.append("\(c.missingObjects) file mancanti nell'archivio") }
            if !c.objects.corrupt.isEmpty { problems.append("\(c.objects.corrupt.count) file danneggiati senza una copia attuale per ripararli") }
            let repaired = c.objects.repaired.isEmpty ? "" : "; \(c.objects.repaired.count) file danneggiati riparati"
            damagedBackups = c.unreadableSnapshots
            otherCheckProblems = c.missingObjects > 0 || !c.objects.corrupt.isEmpty
            if problems.isEmpty {
                archiveProblem = nil
                checkResult = ("Archivio integro: \(c.snapshots) backup, \(c.objects.checked) file controllati (\(size))\(repaired)", true)
                Log.backup.info(checkResult!.text)
            } else {
                checkResult = ("Problemi trovati: " + problems.joined(separator: ", ") + repaired, false)
                Log.backup.error(checkResult!.text)
                if !c.unreadableSnapshots.isEmpty { Log.backup.error("Backup illeggibili: \(c.unreadableSnapshots.joined(separator: ", "))") }
            }
        }
    }

    func deleteDamagedBackups() {
        guard !isRunning, !workerActive, !checkWorkerActive, !deleting, checkProgress == nil, let dest = settings.destination,
              !damagedBackups.isEmpty else { return }
        let ids = damagedBackups, archive = AppPaths.archiveName
        deleting = true
        Task.detached(priority: .userInitiated) {
            let result = Result {
                let repo = try Repository(destination: URL(fileURLWithPath: dest), computerName: archive, create: false)
                try repo.withLock { try repo.claim(owner: getuid()) }
                return try BackupCore.deleteDamagedSnapshots(ids, repository: repo, refsCache: AppPaths.refsCache(archive, destination: repo.root.path))
            }
            await MainActor.run {
                self.deleting = false
                self.deletions += 1
                if self.deferral == Self.deletingDeferral { self.deferral = nil }
                switch result {
                case .failure(let error):
                    self.checkResult = ("Eliminazione non riuscita: \(Self.describe(error))", false)
                case .success(let deleted):
                    self.damagedBackups.removeAll { deleted.contains($0) }
                    let what = deleted.count == 1 ? "Eliminato 1 backup illeggibile" : "Eliminati \(deleted.count) backup illeggibili"
                    Log.backup.info("\(what): \(deleted.joined(separator: ", "))")
                    if self.damagedBackups.isEmpty, !self.otherCheckProblems {
                        self.archiveProblem = nil
                        self.checkResult = ("\(what): l'archivio è integro", true)
                    } else {
                        self.checkResult = ("\(what); restano altri problemi, usa di nuovo Controlla ora", false)
                    }
                }
            }
        }
    }

    private func checkUpload() {
        guard let dest = settings.destination else { uploadProblem = nil; return }
        // one at a time: on a hung destination every hourly check would block a thread until none is left
        guard !uploadCheckRunning else { return }
        uploadCheckRunning = true
        let archive = AppPaths.archiveName
        Task.detached(priority: .utility) {
            let problem = Self.uploadProblem(destination: dest, archive: archive, now: Date())
            Log.backup.debug("Controllo caricamento nel cloud: \(problem ?? "nessun problema")")
            await MainActor.run {
                self.uploadCheckRunning = false
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
              let ids = try? repo.snapshotIDs(), !ids.isEmpty else { return nil }
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemUploadingErrorKey]
        let stale: TimeInterval = 3 * 86400
        var oldestPending: Date?
        for id in ids.reversed() {
            // archive layout (README): snapshots/<id>.json.lzfse
            let url = repo.root.appending(path: "snapshots/\(id).json.lzfse")
            guard let v = try? url.resourceValues(forKeys: keys), v.isUbiquitousItem == true,
                  let uploaded = v.ubiquitousItemIsUploaded else { return nil }
            if let err = v.ubiquitousItemUploadingError { return "Il caricamento non riesce: \(err.localizedDescription)" }
            guard uploaded else { oldestPending = Snapshot.date(fromID: id) ?? oldestPending; continue }
            // the newest uploaded backup: a problem only when the oldest one after it has waited for days, not when it
            // is just old (days without changes, then one backup not uploaded yet)
            guard let pending = oldestPending, now.timeIntervalSince(pending) > stale, let date = Snapshot.date(fromID: id) else { return nil }
            return "L'ultimo backup caricato nel cloud è del \(date.formatted(date: .abbreviated, time: .shortened))"
        }
        guard let oldest = ids.first.flatMap(Snapshot.date(fromID:)), now.timeIntervalSince(oldest) > stale else { return nil }
        return "Nessun backup è ancora stato caricato nel cloud"
    }

    nonisolated static func perform(settings s: AppSettings, archive: String, lastComplete: String?, verify: Bool,
                                    isCancelled: @escaping () -> Bool,
                                    progress: @escaping (Double) -> Void) -> (BackupReport, Bool?, Bool, UpgradeReport?) {
        let start = Date()
        func failed(_ error: Error) -> BackupReport {
            BackupReport(snapshotID: nil, date: start, duration: Date().timeIntervalSince(start), fileCount: 0,
                         newBytes: 0, warnings: [], error: describe(error))
        }
        let repo: Repository
        do {
            repo = try Repository(destination: URL(fileURLWithPath: s.destination ?? ""), computerName: archive)
            // before any write or cleanup: another account's archive is refused, not shared
            try repo.withLock { try repo.claim(owner: getuid()) }
        } catch {
            return (failed(error), nil, false, nil)
        }
        // the first backup of a new build checks what earlier versions left (kit, repo.json, leftovers, manifests)
        let info = Bundle.main.infoDictionary
        let build = "\(info?["CFBundleShortVersionString"] as? String ?? "") (\(info?["CFBundleVersion"] as? String ?? ""))"
        var upgrade: UpgradeReport?
        do { upgrade = try upgradeCheckIfNeeded(repository: repo, build: build) } catch {
            Log.backup.error("Verifica dopo l'aggiornamento non riuscita: \(describe(error))")
        }
        var report: BackupReport
        var thrown: Error?
        let cache = HashCache(url: AppPaths.hashCache(archive))
        do {
            let engine = BackupEngine(repository: repo, cache: cache, excludes: s.excludeRules,
                                        skipUnreadable: s.skipUnreadable)
            report = try engine.run(sources: s.sources.map { URL(fileURLWithPath: $0) }, now: start,
                                    progress: progress, isCancelled: isCancelled)
        } catch {
            thrown = error
            report = failed(error)
            // a write that fails names an archive folder ("in “2e”") or nothing at all: say where and why
            if !(error is RepositoryError || error is BackupError) {
                let gone = !FileManager.default.fileExists(atPath: repo.root.path)
                report.error = gone ? describe(RepositoryError.destinationMissing(s.destination ?? ""))
                    : "Impossibile scrivere nella destinazione \(((s.destination ?? "") as NSString).abbreviatingWithTildeInPath): \(describeWrite(error))"
            }
        }
        if repo.repairedInfo { report.warnings.append("Riparato repo.json, il file che identifica l'archivio: era illeggibile") }
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
                // manifests too, the newest and one at random: one damaged loses its whole backup, and nothing else
                // reads them before a restore
                let ids = (try? repo.snapshotIDs()) ?? []
                for id in Set([ids.last, ids.randomElement()].compactMap { $0 }) where !repo.snapshotIsIntact(id) {
                    report.warnings.append("\(Self.damaged) il backup del \(Snapshot.date(fromID: id)?.formatted(date: .abbreviated, time: .shortened) ?? id) non si legge e non si può ripristinare. Dopo «Controlla ora» lo elimini da Impostazioni › Avanzate.")
                }
                if !v.corrupt.isEmpty {
                    report.warnings.append("\(Self.damaged) \(v.corrupt.count) file non si possono leggere e manca una copia attuale per ripararli: i backup che li usano non si ripristinano per intero")
                }
            } catch {
                report.warnings.append("Verifica dell'archivio non riuscita: \(describe(error))")
            }
        }
        // interrupted, archive locked, or partial with no complete backup to pin: no cleanup (see cleanupDecision)
        guard case .prune(let pinned) = cleanupDecision(thrown: thrown, report: report,
                                                        lastComplete: lastComplete.flatMap { repo.snapshotExists($0) ? $0 : nil })
        else { return (report, nil, verified, upgrade) }
        do {
            // clamp: Int64(x * 1e9) traps above ~9.2e9 GB
            let cap = s.capGB.map { Int64(min($0, 1_000_000) * 1e9) }
            // objects of the backups that leave are collected once a day, not at every hourly backup
            let lastGC = UserDefaults.standard.object(forKey: "lastGC") as? Date
            let gcDue = lastGC.map { Date().timeIntervalSince($0) > 86400 || $0 > Date() } ?? true
            // a failed run may have left orphan objects: collect them (this also frees space when the disk is full)
            let result = try prune(repository: repo, policy: s.retention, capBytes: cap, now: Date(),
                                   refsCache: AppPaths.refsCache(archive, destination: repo.root.path), forceGC: report.snapshotID == nil,
                                   pinned: pinned, gcDue: gcDue)
            if result.collected { UserDefaults.standard.set(Date(), forKey: "lastGC") }
            Log.backup.debug("Pulizia: \(result.deletedSnapshots.count) backup e \(result.deletedObjects) oggetti eliminati, archivio \(result.poolSize) byte, oltre il tetto: \(result.overCap), rinviata: \(result.gcSkipped), oggetti mancanti: \(result.missingObjects)")
            if result.archiveReplaced {
                report.warnings.append("\(Self.recreated) nella destinazione c'è un archivio nuovo e i backup precedenti non ci sono più. Se non l'hai cancellato tu, controlla la cartella: un servizio cloud può averlo spostato o rinominato")
            }
            if result.vanished { report.warnings.append("Pulizia rinviata: alcuni backup sono spariti dalla destinazione, riprende da sola entro 3 giorni") }
            if result.missingObjects > 0 {
                report.warnings.append("\(Self.incomplete) mancano \(result.missingObjects) file usati dai backup, che non si ripristinano per intero")
            }
            return (report, result.overCap, verified, upgrade)
        } catch {
            // the destination unplugged: the backup's own error says it, the archive isn't damaged
            if FileManager.default.fileExists(atPath: repo.root.path) {
                report.warnings.append("Pulizia non riuscita: \(describe(error))")
            }
            return (report, nil, verified, upgrade)
        }
    }

    private func finish(_ report: BackupReport, overCap: Bool?) {
        history.append(report)
        if history.count > 50 { history.removeFirst(history.count - 50) }
        saveHistory()

        if report.error == nil, let id = report.snapshotID { lastComplete = id }
        // warnings that mean a backup can't be fully restored are notified, not just listed
        let critical = report.warnings.filter { w in Self.criticalPrefixes.contains(where: w.hasPrefix) }
        if report.error == Self.describe(BackupError.cancelled) {
            // stopped on purpose: not an error. Retried as after a failure, not a minute later; a "bloccato"
            // message left by the timeout stays
            lastAttempt = Date()
            if isRunning { status = .idle }
            Log.backup.info("Backup interrotto")
        } else if let err = report.error {
            fail(err)
        } else {
            status = .idle
            lastAttempt = nil
            lastSuccess = report.date
            // errors are solved; archive problems still there stay notified once, not at every hourly backup
            notifiedErrors.formIntersection(critical)
            Log.backup.info("Backup \(report.snapshotID ?? "") riuscito: \(report.fileCount) file, \(report.newBytes) byte nuovi, \(Restorer.boundedCount(report.warnings)) avvisi, \(Int(report.duration)) s")
        }
        for w in critical { notifyOnce(w, title: "Problema nell'archivio") }
        if let last = critical.last { archiveProblem = last }
        if report.error == nil, settings.notify != .errors {
            let others = Restorer.boundedCount(report.warnings) - critical.count
            // the same warnings as the backup before (a database always open, a cleanup that waits): told once
            let before = history.dropLast().last?.warnings ?? []
            if others > 0, Set(report.warnings) != Set(before) {
                SystemServices.notify("Backup completato con avvisi",
                                      others == 1 ? "1 avviso: lo trovi nel pannello di BackupMe" : "\(others) avvisi: li trovi nel pannello di BackupMe",
                                      problem: false)
            } else if settings.notify == .all, critical.isEmpty {
                SystemServices.notify("Backup completato", "\(report.fileCount) file, \(report.newBytes.formatted(.byteCount(style: .file))) nuovi",
                                      problem: false)
            }
        }
        if let overCap, overCap != overCapNotified {
            overCapNotified = overCap
            if overCap { SystemServices.notify("BackupMe", "Il tetto è troppo basso per le cartelle selezionate.") }
        }
    }

    /// The check after an update, with what only the app knows (login agent): in the Registro and in one notification
    /// that offers the full check, never started by itself (on OneDrive or iCloud it downloads the whole archive).
    private func reportUpgrade(_ u: UpgradeReport) {
        // manifests not read (offline cloud files): logged, checked again at the next backup, notified once it completes
        guard u.complete else { return Log.backup.error("Verifica dopo l'aggiornamento incompleta: \(u.attention.joined(separator: "; "))") }
        var u = u
        if launchAgentRepaired { u.fixed.append("Avvio al login riparato: puntava a una copia spostata o vecchia di BackupMe") }
        launchAgentRepaired = false // reported once, not again for every destination or later update this session
        if SystemServices.loginItemDisabled {
            u.attention.append("Avvia al login è disattivato in Impostazioni di Sistema › Generali › Elementi login: BackupMe non parte da solo")
        }
        // each item is a sentence of its own (some carry a colon): one Registro line each, a list in the notification
        if u.isClean { Log.backup.info("Aggiornamento verificato: tutto a posto") }
        u.fixed.forEach { Log.backup.info("Aggiornamento verificato, corretto. \($0)") }
        u.attention.forEach { Log.backup.error("Aggiornamento verificato, da controllare. \($0)") }
        let list = { (title: String, items: [String]) in items.isEmpty ? [] : [title] + items.map { "• \($0)" } }
        let lines = list("Corretto", u.fixed) + list("Da controllare", u.attention)
        SystemServices.notify("Aggiornamento verificato",
                              (lines.isEmpty ? "Tutto a posto." : lines.joined(separator: "\n"))
                                  + "\nIl controllo completo rilegge tutto l'archivio: avvialo con Controlla ora.",
                              offerCheck: true)
    }

    private func saveHistory() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        try? enc.encode(history).write(to: AppPaths.history, options: .atomic)
    }

    /// Empties the last backup's warnings, from Impostazioni: the backup itself is untouched.
    /// Empties the last backup's warnings, except the archive problems: those go only when a full check is clean.
    func clearWarnings() {
        guard !history.isEmpty else { return }
        history[history.count - 1].warnings.removeAll { w in !Self.criticalPrefixes.contains(where: w.hasPrefix) }
        saveHistory()
    }

    private func fail(_ message: String) {
        status = .failed(message)
        Log.backup.error("Backup non riuscito: \(message)")
        if message != Self.describe(BackupError.cancelled) { notifyOnce(message) }
    }

    /// One notification per distinct problem until the next successful backup.
    private func notifyOnce(_ message: String, title: String = "Backup non riuscito") {
        guard notifiedErrors.insert(message).inserted else { return }
        SystemServices.notify(title, message)
    }

    nonisolated static func describe(_ error: Error) -> String {
        switch error {
        case RepositoryError.destinationMissing(let p): return "Destinazione non trovata: \(p)"
        case RepositoryError.locked: return "Un altro backup è già in corso"
        case RepositoryError.corruptObject(let h): return "Archivio danneggiato (oggetto \(h.prefix(12)))"
        case RepositoryError.damagedSnapshot(let id):
            return "\(damaged) il backup del \(Snapshot.date(fromID: id)?.formatted(date: .abbreviated, time: .shortened) ?? id) non si legge"
        case RepositoryError.otherOwner:
            return "L'archivio in questa destinazione appartiene a un altro account di questo Mac: scegli un'altra cartella di destinazione per i tuoi backup"
        case RepositoryError.newerFormat(let f):
            return "L'archivio è stato creato da una versione più recente di BackupMe (formato \(f)): aggiorna l'app per continuare i backup"
        case BackupError.sourceOverlapsDestination(let p): return "\((p as NSString).abbreviatingWithTildeInPath) è dentro la destinazione dei backup"
        case BackupError.cancelled: return "Backup interrotto"
        case RestoreError.notFound(let p): return "\(p.isEmpty ? "La cartella" : p) non è in questo backup"
        case RestoreError.invalidEntry(let p): return "Backup non valido o manomesso (percorso \"\(p)\"): ripristino annullato"
        case RestoreError.keptBeside(let p):
            return "Non è stato possibile sostituire: l'originale è nel Cestino e la versione ripristinata è in \(p)"
        case RestoreError.linkInPath(let p):
            return "«\((p as NSString).lastPathComponent)» oggi è un collegamento a un'altra cartella: usa Ripristina in…"
        case RestoreError.containsArchive(let p):
            return "«\((p as NSString).lastPathComponent)» contiene l'archivio dei backup: Sostituisci lo manderebbe nel Cestino. Usa Ripristina accanto o Ripristina in…"
        case let e where BackupEngine.posixCode(e) == ELOOP: return linkInArchive
        // a missing object is named by its hash, which means nothing to anyone
        case let e as CocoaError where e.code == .fileNoSuchFile && e.filePath.map(Repository.isHash) == true:
            return "Manca un file nell'archivio: prova un'altra versione o Impostazioni › Avanzate › Controlla ora"
        default: return error.localizedDescription
        }
    }

    /// Why a write failed, without Foundation's file names (a fan-out folder of the archive means nothing to anyone).
    nonisolated static func describeWrite(_ error: Error) -> String {
        switch BackupEngine.posixCode(error) {
        case ENOSPC: "spazio esaurito"
        case EACCES, EPERM: "permesso negato"
        case EROFS: "il disco è in sola lettura"
        case ENOENT: "cartella dell'archivio non trovata"
        case ELOOP: linkInArchive
        default: error.localizedDescription
        }
    }

    /// ELOOP from the archive's writes, which never follow links: BackupMe, this Mac's folder or a file in it is one.
    nonisolated static var linkInArchive: String {
        "Nell'archivio dei backup c'è un collegamento (symlink) al posto di una cartella o di un file: per sicurezza "
            + "BackupMe non lo segue. Rimettilo come cartella o file normale per riprendere i backup"
    }
}
