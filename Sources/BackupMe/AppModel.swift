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
    /// When cleanups started failing on a read that may work later ("Pulizia rinviata").
    nonisolated static let cleanupDeferredKey = "cleanupDeferredSince"
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
    /// "Prova il kit di ripristino": the backup it would restore, waiting for the user's yes.
    var pendingKitTest: KitTestPlan?
    var kitTestRunning = false
    var kitTestResult: (text: String, ok: Bool)?
    private var kitTestCancel = OSAllocatedUnfairLock(initialState: false)
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
    /// Between going to sleep and the full wake: the timer still fires in the dark wakes (Power Nap, maintenance),
    /// with network and cloud clients not ready, and a backup started there fails or is frozen halfway.
    private var asleep = false
    private var uploadCheckRunning = false
    /// The login agent pointed at a moved or old copy of the app and was rewritten at this launch.
    private var launchAgentRepaired = false

    static let retryAfterFailure: TimeInterval = 15 * 60
    static let staleAfter: TimeInterval = 3 * 86400
    static let stuckAfter: TimeInterval = 2 * 3600

    init() {
        // started by launchd (the login service), reads of a file the cloud client keeps only online fail with EDEADLK
        // instead of downloading it: repo.json, a manifest or a container's index then stop the backup. Sources are
        // not affected: the engine never opens a file that is only in the cloud
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_ON)
        SystemServices.quitIfAlreadyRunning()
        // the inspector's card copies are deleted once read: what is left was left by a crash, and nothing has it open
        try? FileManager.default.removeItem(at: RestoreModel.cardCopies)
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
        launchAgentRepaired = SystemServices.repairLaunchAgent()
        if SystemServices.handOverToLaunchAgent() {
            if launchAgentRepaired { Log.app.info("Avvio al login riparato: puntava a una copia spostata o vecchia di BackupMe") }
            Log.app.info("Avviato come servizio di login: macOS lo riavvia se si chiude per errore")
            Log.flush()
            exit(0)
        }
        // asked in context: the first-run window asks when the first backup starts
        if settings.isConfigured { SystemServices.requestNotificationPermission() }
        updateRestoreKit()
        _ = SystemServices.network
        // common modes: in the default mode it doesn't fire while an open panel or a menu is up
        let timer = Timer(timeInterval: 60, repeats: true) { _ in MainActor.assumeIsolated { self.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            // shortcut: a wake without didWake would hold scheduled backups until restart; the 3-day notice still fires
            MainActor.assumeIsolated { self.asleep = true }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            // give network and OneDrive a minute after wake: the 60 s timer may fire seconds after it
            MainActor.assumeIsolated { self.asleep = false; self.wokeAt = ProcessInfo.processInfo.systemUptime }
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { MainActor.assumeIsolated { self.tick() } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { MainActor.assumeIsolated { self.tick() } }
    }

    /// An update may bring a new RIPRISTINO.command: written beside the archives at launch, not at the next backup.
    /// Off the main thread: a network destination can take long to answer.
    private func updateRestoreKit() {
        guard let dest = settings.destination else { return }
        Task.detached(priority: .utility) {
            switch Repository.updateRestoreKit(destination: URL(fileURLWithPath: dest)) {
            case .installed(let from, let to):
                Log.app.info("Kit di ripristino aggiornato \(from.map { "dalla versione \($0) " } ?? "")alla versione \(to) in \(dest)/BackupMe")
            case .newerKept(let v):
                Log.app.info("Kit di ripristino lasciato alla versione \(v), più recente di questa app (scritto da un altro Mac)")
            case .current, .noArchive: break // nothing to say; the first backup writes the kit with the archive
            }
        }
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
        // "Esegui ora" still runs while asleep; only the scheduled ones wait for the full wake
        guard !asleep, ProcessInfo.processInfo.systemUptime - wokeAt >= 60 else { return }
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
            }.mapError { Self.unplugged($0, destination: dest, archive: archive) }
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

    /// First step of "Prova il kit di ripristino": the latest backup and its size, so the user knows what the test
    /// restores (and downloads, from a cloud folder) before saying yes.
    func prepareKitTest() {
        guard !kitTestRunning, let dest = settings.destination else { return }
        kitTestResult = nil
        let archive = AppPaths.archiveName
        Task.detached(priority: .userInitiated) {
            let plan = Result {
                try kitTestPlan(repository: Repository(destination: URL(fileURLWithPath: dest), computerName: archive, create: false))
            }.mapError { Self.unplugged($0, destination: dest, archive: archive) }
            await MainActor.run {
                switch plan {
                case .success(let p?): self.pendingKitTest = p
                case .success(nil): self.kitTestResult = ("Nessun backup da provare: fai prima un backup", false)
                case .failure(let e): self.kitTestResult = (Self.describe(e), false)
                }
            }
        }
    }

    /// RIPRISTINO.command restores the backup into a temporary folder, as on a Mac without BackupMe; every file is
    /// compared with the index, then the folder is deleted.
    func runKitTest(_ plan: KitTestPlan) {
        pendingKitTest = nil
        guard !kitTestRunning, let dest = settings.destination else { return }
        kitTestRunning = true
        let flag = OSAllocatedUnfairLock(initialState: false)
        kitTestCancel = flag
        let archive = AppPaths.archiveName
        Log.restore.info("Prova del kit di ripristino sul backup \(plan.snapshotID) avviata")
        Task.detached(priority: .utility) {
            let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "Prova del kit di ripristino")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            let work = FileManager.default.temporaryDirectory.appending(path: "BackupMe-prova-kit-\(UUID().uuidString)")
            let result = Result {
                let repo = try Repository(destination: URL(fileURLWithPath: dest), computerName: archive, create: false)
                return try testRestoreKit(repository: repo, snapshotID: plan.snapshotID, into: work) { flag.withLock { $0 } }
            }.mapError { Self.unplugged($0, destination: dest, archive: archive) }
            await MainActor.run {
                self.kitTestRunning = false
                switch result {
                case .success(let t) where t.passed:
                    let when = Snapshot.date(fromID: t.snapshotID)?.formatted(date: .abbreviated, time: .shortened) ?? t.snapshotID
                    self.kitTestResult = ("RIPRISTINO.command versione \(t.installed ?? 0) funziona: ripristinati e verificati \(t.files) file del backup del \(when)", true)
                    Log.restore.info("Prova del kit di ripristino riuscita: \(t.files) file verificati")
                case .success(let t):
                    self.kitTestResult = (t.problems.joined(separator: "\n"), false)
                    Log.restore.error("Prova del kit di ripristino non riuscita: \(t.problems.joined(separator: " | "))")
                case .failure(BackupError.cancelled):
                    self.kitTestResult = ("Prova interrotta", false)
                case .failure(let e):
                    self.kitTestResult = (Self.describe(e), false)
                    Log.restore.error("Prova del kit di ripristino non riuscita: \(Self.describe(e))")
                }
            }
        }
    }

    func cancelKitTest() { kitTestCancel.withLock { $0 = true } }

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
            if !c.unreadableSnapshots.isEmpty {
                problems.append(c.unreadableSnapshots.count == 1 ? "1 backup illeggibile, che non si può ripristinare"
                                : "\(c.unreadableSnapshots.count) backup illeggibili, che non si possono ripristinare")
            }
            if !c.unreadSnapshots.isEmpty {
                problems.append(c.unreadSnapshots.count == 1 ? "1 backup non si è potuto leggere (forse non ancora scaricato dal cloud): riprova con il client cloud attivo"
                                : "\(c.unreadSnapshots.count) backup non si sono potuti leggere (forse non ancora scaricati dal cloud): riprova con il client cloud attivo")
            }
            if c.missingObjects > 0 { problems.append("\(c.missingObjects) file mancanti nell'archivio") }
            if !c.objects.corrupt.isEmpty { problems.append("\(c.objects.corrupt.count) file danneggiati senza una copia attuale per ripararli") }
            if !c.damagedPacks.isEmpty { problems.append(c.damagedPacks.count == 1 ? "1 contenitore danneggiato" : "\(c.damagedPacks.count) contenitori danneggiati") }
            let repaired = c.objects.repaired.isEmpty ? "" : "; \(c.objects.repaired.count) file danneggiati riparati"
            damagedBackups = c.unreadableSnapshots
            otherCheckProblems = c.missingObjects > 0 || !c.objects.corrupt.isEmpty || !c.damagedPacks.isEmpty || !c.unreadSnapshots.isEmpty
            if problems.isEmpty {
                archiveProblem = nil
                checkResult = ("Archivio integro: \(c.snapshots) backup, \(c.objects.checked) file controllati (\(size))\(repaired)", true)
                Log.backup.info(checkResult!.text)
            } else {
                // only backups not read (not downloaded yet, a destination not answering): the damage once noticed is
                // not confirmed, and its «lo elimini» would point to an Elimina button that isn't there
                if c.unreadableSnapshots.isEmpty, c.missingObjects == 0, c.objects.corrupt.isEmpty, c.damagedPacks.isEmpty { archiveProblem = nil }
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
            }.mapError { Self.unplugged($0, destination: dest, archive: archive) }
            await MainActor.run {
                self.deleting = false
                self.deletions += 1
                if self.deferral == Self.deletingDeferral { self.deferral = nil }
                switch result {
                case .failure(let error):
                    self.checkResult = ("Eliminazione non riuscita: \(Self.describe(error))", false)
                case .success(let deleted) where deleted.isEmpty:
                    // they read now, or can't be reached: nothing known to be damaged is left to delete
                    self.damagedBackups = []
                    self.checkResult = ("Nessun backup eliminato: ora si leggono, o la destinazione non risponde. Ripeti Controlla ora", false)
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
            repo = try Repository(destination: URL(fileURLWithPath: s.destination ?? ""), computerName: archive,
                                  packBelow: Repository.packThreshold)
            // before any write or cleanup: another account's archive is refused, not shared
            try repo.withLock { try repo.claim(owner: getuid()) }
        } catch {
            return (failed(error), nil, false, nil)
        }
        // what the last collection found unused: this backup must not reuse an object the cleanup may delete
        repo.condemned = condemnedObjects(refsCache: AppPaths.refsCache(archive, destination: repo.root.path))
        // the client behind on what was already there: deleting now would leave the cloud copy without what replaces
        // it. Read before the backup, whose own files are not uploaded yet by definition. Only an explicit "not uploaded"
        // counts: a client that says nothing would block every cleanup (each hourly backup writes a new container)
        let uploaded = { (path: String) -> Bool? in
            let v = try? repo.root.appending(path: path).resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey])
            return v?.isUbiquitousItem == true ? v?.ubiquitousItemIsUploaded : nil
        }
        // archive layout (README): packs/<id>.pack and .idx, snapshots/<id>.json.lzfse
        let packs = (try? repo.packIDs()) ?? []
        let lastPackConfirmed = packs.last.map { id in ["pack", "idx"].allSatisfy { uploaded("packs/\(id).\($0)") != false } } ?? true
        let manifestUploaded = ((try? repo.snapshotIDs()) ?? []).last.flatMap { uploaded("snapshots/\($0).json.lzfse") }
        let clientBehind = manifestUploaded == false || !lastPackConfirmed
        Log.backup.debug("Contenitori: \(packs.count), ultimo confermato: \(lastPackConfirmed ? "sì" : "no"), il client dichiara lo stato di caricamento: \(manifestUploaded != nil ? "sì" : "no")")
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
                    : "Impossibile usare la destinazione \(((s.destination ?? "") as NSString).abbreviatingWithTildeInPath): \(describeWrite(deadDescriptor(error, root: repo.root)))"
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
                for id in Set([ids.last, ids.randomElement()].compactMap { $0 }) where repo.snapshotDamaged(id) == true {
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
        // deletions of the last hour, across backups: OneDrive alerts on many files deleted within an hour
        let defaults = UserDefaults.standard
        var ledger = defaults.data(forKey: "deletionLedger").flatMap { try? JSONDecoder().decode(DeletionLedger.self, from: $0) } ?? DeletionLedger()
        var options = CleanupOptions()
        options.maxDeletions = clientBehind ? 0 : ledger.allowance(limit: defaults.object(forKey: "deletionsPerHour") as? Int ?? 50, now: Date())
        options.convert = true
        // saved spent before the deletions: a quit or crash before the real count is saved must not leave a full allowance
        var spent = ledger
        spent.record(options.maxDeletions ?? 0, at: Date())
        defaults.set(try? JSONEncoder().encode(spent), forKey: "deletionLedger")
        do {
            // clamp: Int64(x * 1e9) traps above ~9.2e9 GB
            let cap = s.capGB.map { Int64(min($0, 1_000_000) * 1e9) }
            // objects of the backups that leave are collected once a day, not at every hourly backup
            let lastGC = defaults.object(forKey: "lastGC") as? Date
            let gcDue = lastGC.map { Date().timeIntervalSince($0) > 86400 || $0 > Date() } ?? true
            // never forced after a failed run: what it copied is what the next attempt needs, and deleting it was
            // thousands of files removed from the cloud and uploaded again. Over the cap they are collected anyway
            let result = try prune(repository: repo, policy: s.retention, capBytes: cap, now: Date(),
                                   refsCache: AppPaths.refsCache(archive, destination: repo.root.path),
                                   pinned: pinned, gcDue: gcDue, options: options)
            ledger.record(result.deletedFiles, at: Date())
            defaults.set(try? JSONEncoder().encode(ledger), forKey: "deletionLedger")
            if result.collected { defaults.set(Date(), forKey: "lastGC") }
            // nil: not counted in this call, the last count stays
            let smallBefore = defaults.object(forKey: "smallFilesLeft") as? Int
            if let small = result.smallFilesLeft {
                defaults.set(small, forKey: "smallFilesLeft")
                // the pace of the conversion is measured from when it started (Destinazione's end estimate)
                if small == 0 {
                    defaults.removeObject(forKey: "conversionStartCount")
                    defaults.removeObject(forKey: "conversionStartDate")
                } else if defaults.object(forKey: "conversionStartDate") == nil {
                    defaults.set(small, forKey: "conversionStartCount")
                    defaults.set(Date(), forKey: "conversionStartDate")
                }
            }
            // in the Registro at any log level: the count to compare with a cloud service's "many files deleted" alert
            if result.deletedFiles > 0 || (result.smallFilesLeft.map { $0 != smallBefore ?? 0 } ?? false) {
                let small = result.smallFilesLeft.map { $0 == 0 ? "" : ", \($0) file piccoli da convertire" } ?? ""
                Log.backup.info("Pulizia: \(result.deletedFiles) file eliminati dalla destinazione\(small)")
            }
            Log.backup.debug("Pulizia: \(result.deletedSnapshots.count) backup e \(result.deletedObjects) oggetti eliminati, archivio \(result.poolSize) byte, oltre il tetto: \(result.overCap), rientro rinviato: \(result.capPending), eliminazioni consentite: \(options.maxDeletions ?? 0), rinviata: \(result.gcSkipped), oggetti mancanti: \(result.missingObjects)")
            if result.archiveReplaced {
                report.warnings.append("\(Self.recreated) nella destinazione c'è un archivio nuovo e i backup precedenti non ci sono più. Se non l'hai cancellato tu, controlla la cartella: un servizio cloud può averlo spostato o rinominato")
            }
            if result.vanished { report.warnings.append("Pulizia rinviata: alcuni backup sono spariti dalla destinazione, riprende da sola entro 3 giorni") }
            if result.missingObjects > 0 {
                report.warnings.append("\(Self.incomplete) mancano \(result.missingObjects) file usati dai backup, che non si ripristinano per intero")
            }
            defaults.removeObject(forKey: Self.cleanupDeferredKey)
            // an archive still shrinking within the hourly budget says nothing about the cap: nil keeps the last notice
            return (report, result.capPending ? nil : result.overCap, verified, upgrade)
        } catch {
            // it may have deleted before throwing: the whole allowance counts as spent, retries within the hour get none
            ledger.record(options.maxDeletions ?? 0, at: Date())
            defaults.set(try? JSONEncoder().encode(ledger), forKey: "deletionLedger")
            // the destination unplugged: the backup's own error says it, the archive isn't damaged
            // a read failing for a moment after a sleep is not damage: the next backup cleans up again. Deferred for
            // more than 3 days it is no moment: critical again, or the archive would grow without cleanup in silence
            let since = defaults.object(forKey: Self.cleanupDeferredKey) as? Date ?? Date()
            if FileManager.default.fileExists(atPath: repo.root.path) {
                if BackupEngine.isTransient(error), Date().timeIntervalSince(since) < 3 * 86400 {
                    defaults.set(since, forKey: Self.cleanupDeferredKey)
                    report.warnings.append(notAnswering.contains(BackupEngine.posixCode(error) ?? 0)
                        ? "Pulizia rinviata: la destinazione non risponde (capita dopo lo standby), riprende da sola al prossimo backup"
                        : "Pulizia rinviata, riprende da sola al prossimo backup: \(describe(error))")
                } else {
                    report.warnings.append("Pulizia non riuscita: \(describe(error))")
                }
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
        // the text sends to Controlla ora: the notification offers it, not Riprova
        for w in critical where notifiedErrors.insert(w).inserted { SystemServices.notify("Problema nell'archivio", w, offerCheck: true) }
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
    private func notifyOnce(_ message: String) {
        guard notifiedErrors.insert(message).inserted else { return }
        SystemServices.notify("Backup non riuscito", message)
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
        case RestoreError.inCloudFolder(let p, let service):
            return "Sostituisci «\((p as NSString).lastPathComponent)» toccherebbe file di \(service), che potrebbe eliminarli subito invece di spostarli nel Cestino. Usa Ripristina accanto o Ripristina in…"
        case let e where BackupEngine.posixCode(e) == ELOOP: return linkInArchive
        case let e where notAnswering.contains(BackupEngine.posixCode(e) ?? 0):
            return "Il disco o il servizio cloud non risponde (capita subito dopo lo standby): riprova fra qualche minuto; se si ripete, controlla il disco"
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
        case let c? where notAnswering.contains(c): "non risponde o si è scollegata (capita dopo lo standby). BackupMe riprova da solo entro 15 minuti"
        default: error.localizedDescription
        }
    }

    /// A disk, a share or a cloud folder not answering, mostly right after a sleep: worth a retry, not damage.
    nonisolated static let notAnswering: Set<Int32> = [EIO, ETIMEDOUT, ENXIO, ESTALE, EDEADLK, ENOTCONN, EAGAIN, ENETDOWN,
                                                        EHOSTDOWN, EHOSTUNREACH]

    /// An operation on the archive (check, deletion, kit test, restore) that failed with the destination gone, or
    /// unplugged under its open folder, is said as such: not Foundation's "Not a directory" or the name of a file in
    /// the archive. Off the main thread: it looks at the disk.
    nonisolated static func unplugged(_ error: Error, destination: String, archive: String) -> Error {
        guard !(error is BackupError), !(error is RepositoryError) else { return error }
        if !Repository.isAvailable(destination: URL(fileURLWithPath: destination)) { return RepositoryError.destinationMissing(destination) }
        return deadDescriptor(error, root: URL(fileURLWithPath: destination).appending(path: "BackupMe").appending(path: archive))
    }

    /// ENOTDIR or EBADF from the open folder of a volume detached and mounted again: told as a device not answering
    /// (ENXIO). Not with the archive's layout wrong (packs/ or snapshots/ turned into a file): that one never answers.
    nonisolated static func deadDescriptor(_ error: Error, root: URL) -> Error {
        guard let c = BackupEngine.posixCode(error), c == ENOTDIR || c == EBADF else { return error }
        let sound = [root.deletingLastPathComponent(), root, root.appending(path: "objects"), root.appending(path: "snapshots"),
                     root.appending(path: "packs")].allSatisfy { url in
            var st = stat()
            return lstat(url.path, &st) != 0 || st.st_mode & S_IFMT == S_IFDIR
        }
        return c == EBADF || sound ? POSIXError(.ENXIO) : error
    }

    /// ELOOP from the archive's writes, which never follow links: BackupMe, this Mac's folder or a file in it is one.
    nonisolated static var linkInArchive: String {
        "Nell'archivio dei backup c'è un collegamento (symlink) al posto di una cartella o di un file: per sicurezza "
            + "BackupMe non lo segue. Rimettilo come cartella o file normale per riprendere i backup"
    }
}
