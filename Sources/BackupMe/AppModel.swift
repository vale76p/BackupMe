import AppKit
import BackupCore
import Foundation
import os

enum BackupStatus: Equatable { case idle, running(Double), failed(String) }

@MainActor @Observable final class AppModel {
    var settings = AppSettings.load() { didSet { settings.save() } }
    var status: BackupStatus = .idle
    var history: [BackupReport] = []

    var lastSuccess: Date? { history.last { $0.error == nil }?.date }
    var isRunning: Bool { if case .running = status { true } else { false } }

    private var cancelFlag = OSAllocatedUnfairLock(initialState: false)
    private var lastAttempt: Date?
    private var lastStaleNotice: Date?
    private var timer: Timer?
    private let log = Logger(subsystem: "com.vale76p.BackupMe", category: "backup")

    static let retryAfterFailure: TimeInterval = 15 * 60
    static let staleAfter: TimeInterval = 3 * 86400

    init() {
        if let data = try? Data(contentsOf: AppPaths.history) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
            history = (try? dec.decode([BackupReport].self, from: data)) ?? []
        }
        SystemServices.requestNotificationPermission()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            // give network and OneDrive a minute after wake
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { MainActor.assumeIsolated { self.tick() } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { MainActor.assumeIsolated { self.tick() } }
    }

    func repository(computer: String? = nil) throws -> Repository {
        guard let dest = settings.destination else { throw RepositoryError.destinationMissing("") }
        return try Repository(destination: URL(fileURLWithPath: dest), computerName: computer ?? AppPaths.computerName)
    }

    func tick(now: Date = Date()) {
        if let last = lastSuccess, now.timeIntervalSince(last) > Self.staleAfter,
           lastStaleNotice.map({ now.timeIntervalSince($0) > 86400 }) ?? true {
            lastStaleNotice = now
            SystemServices.notify("BackupMe", "Nessun backup riuscito da più di 3 giorni.")
        }
        guard !settings.paused, settings.isConfigured, !isRunning,
              isBackupDue(lastSuccess: lastSuccess, intervalHours: settings.intervalHours, now: now),
              lastAttempt.map({ now.timeIntervalSince($0) >= Self.retryAfterFailure }) ?? true else { return }
        backupNow()
    }

    func backupNow() {
        guard !isRunning else { return }
        guard settings.isConfigured else {
            status = .failed("Scegli cartelle e destinazione nelle Impostazioni")
            return
        }
        lastAttempt = Date()
        status = .running(0)
        let flag = OSAllocatedUnfairLock(initialState: false)
        cancelFlag = flag
        let s = settings
        let computer = AppPaths.computerName
        Task.detached(priority: .utility) {
            var lastSent = 0.0
            let (report, overCap) = Self.perform(settings: s, computer: computer, isCancelled: { flag.withLock { $0 } }) { p in
                guard p - lastSent >= 0.01 || p == 1 else { return }
                lastSent = p
                Task { @MainActor in if self.isRunning { self.status = .running(p) } }
            }
            await MainActor.run { self.finish(report, overCap: overCap) }
        }
    }

    func cancelBackup() { cancelFlag.withLock { $0 = true } }

    nonisolated static func perform(settings s: AppSettings, computer: String, isCancelled: @escaping () -> Bool,
                                    progress: @escaping (Double) -> Void) -> (BackupReport, Bool) {
        let start = Date()
        do {
            let repo = try Repository(destination: URL(fileURLWithPath: s.destination ?? ""), computerName: computer)
            let engine = BackupEngine(repository: repo, cache: HashCache(url: AppPaths.hashCache(computer)),
                                      excludes: ExcludeRules(patterns: s.excludes))
            var report = try engine.run(sources: s.sources.map { URL(fileURLWithPath: $0) }, now: start,
                                        progress: progress, isCancelled: isCancelled)
            var overCap = false
            do {
                overCap = try prune(repository: repo, policy: s.retention, capBytes: s.capGB.map { Int64($0 * 1e9) }, now: Date()).overCap
            } catch {
                report.warnings.append("Pulizia non riuscita: \(describe(error))")
            }
            return (report, overCap)
        } catch {
            return (BackupReport(snapshotID: nil, date: start, duration: Date().timeIntervalSince(start), fileCount: 0,
                                 newBytes: 0, warnings: [], error: describe(error)), false)
        }
    }

    private func finish(_ report: BackupReport, overCap: Bool) {
        let previousError = history.last?.error
        history.append(report)
        if history.count > 50 { history.removeFirst(history.count - 50) }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        try? enc.encode(history).write(to: AppPaths.history, options: .atomic)

        if let err = report.error {
            status = .failed(err)
            log.error("backup failed: \(err, privacy: .public)")
            // one notification per distinct error, not one per retry
            if err != previousError, err != Self.describe(BackupError.cancelled) { SystemServices.notify("Backup non riuscito", err) }
        } else {
            status = .idle
            lastAttempt = nil
            log.info("backup \(report.snapshotID ?? "", privacy: .public): \(report.fileCount) files, \(report.newBytes) new bytes, \(report.warnings.count) warnings")
        }
        if overCap {
            SystemServices.notify("BackupMe", "Il tetto è troppo basso per le cartelle selezionate.")
        }
    }

    nonisolated static func describe(_ error: Error) -> String {
        switch error {
        case RepositoryError.destinationMissing(let p): return "Destinazione non trovata: \(p)"
        case RepositoryError.locked: return "Un altro backup è già in corso"
        case RepositoryError.corruptObject(let h): return "Archivio danneggiato (oggetto \(h.prefix(12)))"
        case BackupError.sourceMissing(let p): return "Cartella non trovata: \(p)"
        case BackupError.sourceOverlapsDestination(let p): return "La cartella \(p) contiene la destinazione o è al suo interno"
        case BackupError.cancelled: return "Backup interrotto"
        default: return error.localizedDescription
        }
    }
}
