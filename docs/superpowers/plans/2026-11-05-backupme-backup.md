# BackupMe — modulo Backup: piano di implementazione

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** App macOS da barra dei menu che fa backup deduplicati di cartelle di progetti verso una cartella (OneDrive sincronizzato), con retention, tetto del pool e ripristino stile Finder.

**Architecture:** Package SwiftPM con una libreria `BackupCore` senza UI (archivio, backup, retention, pulizia, ripristino), tutta testata, e un eseguibile SwiftUI `BackupMe` (MenuBarExtra, impostazioni, finestra di ripristino, pianificatore). Uno script assembla il bundle `.app`, lo firma ad-hoc e lo copia in `~/Applications`.

**Tech Stack:** Swift 6, SwiftUI, Foundation, CryptoKit (SHA-256), compressione LZFSE di Foundation (`NSData.compressed(using: .lzfse)`), ServiceManagement, UserNotifications, Swift Testing. Nessuna dipendenza esterna.

**Spec:** `docs/superpowers/specs/2026-11-05-backupme-backup-design.md`

**Stato (1.0):** piano eseguito. Ogni task ha il suo commit (Task 1 `65fcc19`, 2 `aec17e1`, 3 `bf0850b`, 4 `5ea8deb`, 5 `e849c5b`, 6 `1c5418c`, 7 `5045a53`, 8 `6d0b158`, 9 `92b088e`) con i file e i test che il task elenca. I passi "Run → FAIL" non lasciano traccia; sono spuntati perché i test che descrivono sono nel commit del task. Le quattro verifiche manuali (Task 6 step 6, Task 7 step 2, Task 8 step 3, Task 9 step 2) non hanno un esito registrato: restano vuote e rimandano a [#24](https://github.com/vale76p/BackupMe/issues/24). Diverse note di implementazione sono state superate dalle versioni successive (lock con `flock` invece di `{pid, host}`, LaunchAgent invece di `SMAppService`, nome dell'archivio): vedi "Differenze rispetto alla spec" nella spec e `docs/formato-archivio.md`.

## Global Constraints

- macOS 14+ (`platforms: [.macOS(.v14)]`, `LSMinimumSystemVersion` 14.0).
- Nessuna dipendenza esterna; nessun codice git (modulo successivo).
- Nessun permesso di amministratore; app non sandboxata; firma ad-hoc `codesign -s -`.
- Archivio in chiaro; nessun hard link.
- Layout: `<destinazione>/BackupMe/<nome computer>/{repo.json, objects/xx/<sha256>.lzfse, snapshots/<id>.json.lzfse, lock}`.
- ID snapshot = data UTC nel formato `yyyy-MM-dd'T'HH-mm-ss'Z'` (es. `2026-11-05T10-00-00Z`).
- Esclusioni di default: `node_modules`, `.build`, `DerivedData`, `build`, `dist`, `.venv`, `venv`, `__pycache__`, `.DS_Store`, `Pods`, `.gradle`, `target`. `.git` è sempre incluso.
- Retention di default: tutti nelle ultime 24 h, 14 giorni, 8 settimane (lunedì-domenica), 12 mesi, nel fuso locale; il più recente si tiene sempre.
- Tetto del pool di default: nessuno.
- Intervalli: 1, 2, 4, 6, 12, 24 ore (default 1).
- Nome file ripristinato: `nome (ripristinato 5 nov 10.00).ext` (locale `it_IT`, formato `d MMM HH.mm`).
- Il ripristino non sovrascrive mai; "Sostituisci" sposta prima l'attuale nel Cestino.
- Testi UI in italiano.

## Review Focus

- Destinazione assente (OneDrive scollegato) → errore `destinationMissing`, nessuna cartella creata al posto della destinazione. Test in Task 1.
- File illeggibile (permessi 000) in una sorgente → avviso nel manifest, backup completato. Test in Task 2.
- Nomi con spazi, accenti, emoji; file e cartelle vuote; symlink rotti → round-trip identico. Test in Task 5.
- Lock rimasto da un processo morto → rimosso; lock di un processo vivo → `locked`. Test in Task 1.
- Cartella con permessi di sola lettura (`0555`) nel backup → il ripristino scrive i figli e applica i permessi della cartella per ultimi. Test in Task 5.

---

### Task 1: Package, modelli e archivio

**Files:**
- Create: `Package.swift`
- Create: `Sources/BackupCore/Models.swift`
- Create: `Sources/BackupCore/Repository.swift`
- Test: `Tests/BackupCoreTests/RepositoryTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum EntryKind: String, Codable { case file, directory, symlink }
  public struct Entry: Codable, Equatable, Hashable {
      public var source: String      // percorso assoluto della cartella sorgente
      public var path: String        // relativo alla sorgente; "" = la sorgente stessa
      public var kind: EntryKind
      public var hash: String?       // solo .file
      public var size: Int64
      public var mtime: Date
      public var mode: UInt16        // permessi POSIX
      public var linkTarget: String? // solo .symlink
  }
  public struct Snapshot: Codable {
      public var id: String; public var date: Date
      public var sources: [String]; public var entries: [Entry]; public var warnings: [String]
      public static func id(for date: Date) -> String
      public static func date(fromID id: String) -> Date?   // inverso di id(for:)
  }
  public enum RepositoryError: Error, Equatable {
      case destinationMissing(String), locked(pid: Int32, host: String), corruptObject(String)
  }
  public final class Repository {
      public let root: URL
      public init(destination: URL, computerName: String) throws
      public static func computers(in destination: URL) -> [String]
      public func hasObject(_ hash: String) -> Bool
      public func putObject(_ data: Data, hash: String) throws -> Int64   // byte scritti
      public func readObject(_ hash: String) throws -> Data               // verifica SHA-256
      public func snapshotIDs() throws -> [String]                        // crescenti
      public func writeSnapshot(_ s: Snapshot) throws
      public func readSnapshot(_ id: String) throws -> Snapshot
      public func deleteSnapshot(_ id: String) throws
      public func allObjectHashes() throws -> Set<String>
      public func deleteObject(_ hash: String) throws
      public func removeTemporaryFiles() throws
      public func poolSize() throws -> Int64
      public func withLock<T>(_ body: () throws -> T) throws -> T
  }
  public func sha256Hex(_ data: Data) -> String
  ```

- [x] **Step 1: Crea `Package.swift`** con `platforms: [.macOS(.v14)]`, target `BackupCore` (library), `BackupMe` (executableTarget, dipende da `BackupCore`, per ora solo un `main.swift` vuoto o un `@main` minimo), `BackupCoreTests` (testTarget). Run: `swift build` → successo.

- [x] **Step 2: Scrivi i test che falliscono** in `RepositoryTests.swift` (ognuno usa una cartella temporanea come destinazione):
  ```swift
  @Test func missingDestinationThrows() {
      let dest = tmp().appending(path: "non-esiste")
      #expect(throws: RepositoryError.destinationMissing(dest.path)) { try Repository(destination: dest, computerName: "Mac") }
      #expect(!FileManager.default.fileExists(atPath: dest.path))
  }
  @Test func createsLayout() throws { // root = dest/BackupMe/Mac, contiene repo.json, objects/, snapshots/
      let r = try Repository(destination: dest, computerName: "Mac")
      #expect(r.root.path.hasSuffix("BackupMe/Mac"))
      #expect(Repository.computers(in: dest) == ["Mac"])
  }
  @Test func objectRoundTrip() throws {
      let data = Data("ciao".utf8); let h = sha256Hex(data)
      _ = try r.putObject(data, hash: h)
      #expect(r.hasObject(h)); #expect(try r.readObject(h) == data)
      #expect(FileManager.default.fileExists(atPath: r.root.appending(path: "objects/\(h.prefix(2))/\(h).lzfse").path))
  }
  @Test func corruptObjectDetected() // sovrascrivi il file oggetto con altri dati compressi → readObject lancia .corruptObject(h)
  @Test func snapshotRoundTripAndOrder() // scrivi id 2026-11-05T10-00-00Z e 2026-11-04T10-00-00Z → snapshotIDs() == [04, 05]; readSnapshot == scritto; deleteSnapshot lo rimuove
  @Test func snapshotIDFormat() { #expect(Snapshot.id(for: Date(timeIntervalSince1970: 0)) == "1970-01-01T00-00-00Z")
      #expect(Snapshot.date(fromID: "1970-01-01T00-00-00Z") == Date(timeIntervalSince1970: 0)); #expect(Snapshot.date(fromID: "x") == nil) }
  @Test func liveLockRefuses() // scrivi lock con pid = getpid() e host corrente → withLock lancia .locked
  @Test func staleLockRemoved() // lock con pid 999999 (non esistente) e host corrente → withLock esegue il body e poi il lock non esiste più
  @Test func temporaryFilesRemoved() // crea objects/ab/x.tmp → removeTemporaryFiles() lo elimina
  ```

- [x] **Step 3: Run** `swift test --filter RepositoryTests` → FAIL (tipi non definiti).

- [x] **Step 4: Implementa `Models.swift` e `Repository.swift`.** Note:
  - `init` non crea mai `destination`: se manca lancia `destinationMissing(destination.path)`; crea solo `BackupMe/<nome>/…` e `repo.json` (`{"format":1,"id":UUID,"created":Date}`) se assenti. Nel nome computer sostituisci `/` e `:` con `-`.
  - `hasObject` usa un `Set<String>` caricato pigramente elencando `objects/*/` (elencare non scarica i file da OneDrive) e aggiornato da put/delete.
  - Scrittura atomica: scrivi `<nome>.tmp` nella stessa cartella, poi `FileManager.moveItem`/`replaceItemAt`. Vale per oggetti, manifest e `repo.json`.
  - Manifest: `JSONEncoder` (date `.secondsSince1970`, `sortedKeys`) poi LZFSE.
  - Lock: file JSON `{pid, host}`; è stale se l'host coincide e `kill(pid, 0) != 0 && errno == ESRCH`. Lock di un altro host: trattalo come vivo.
  - `poolSize` = somma delle dimensioni dei file in `objects/` e `snapshots/`.

- [x] **Step 5: Run** `swift test --filter RepositoryTests` → PASS.

- [x] **Step 6: Commit** `git add Package.swift Sources Tests && git commit -m "feat(core): archivio con oggetti deduplicati, manifest e lock"`

---

### Task 2: Scansione, cache degli hash e backup

**Files:**
- Create: `Sources/BackupCore/Excludes.swift`
- Create: `Sources/BackupCore/HashCache.swift`
- Create: `Sources/BackupCore/BackupEngine.swift`
- Test: `Tests/BackupCoreTests/BackupEngineTests.swift`

**Interfaces:**
- Consumes: `Repository`, `Snapshot`, `Entry`, `sha256Hex` (Task 1).
- Produces:
  ```swift
  public struct ExcludeRules { public static let defaults: [String]; public init(patterns: [String]); public func excludes(name: String) -> Bool }
  public final class HashCache { public init(url: URL); public func lookup(path: String, inode: UInt64, size: Int64, mtime: Date) -> String?
      public func store(path: String, inode: UInt64, size: Int64, mtime: Date, hash: String); public func save() throws }
  public struct BackupReport: Codable { public var snapshotID: String?; public var date: Date; public var duration: TimeInterval
      public var fileCount: Int; public var newBytes: Int64; public var warnings: [String]; public var error: String? }
  public enum BackupError: Error, Equatable { case sourceMissing(String), sourceOverlapsDestination(String), cancelled }
  public final class BackupEngine {
      public init(repository: Repository, cache: HashCache, excludes: ExcludeRules)
      public static func validate(sources: [URL], repositoryRoot: URL) -> BackupError?
      public func run(sources: [URL], now: Date = Date(), progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }) throws -> BackupReport
  }
  ```

- [x] **Step 1: Scrivi i test che falliscono:**
  ```swift
  @Test func excludesByName() { let r = ExcludeRules(patterns: ExcludeRules.defaults + ["*.log"])
      #expect(r.excludes(name: "node_modules")); #expect(r.excludes(name: "x.log")); #expect(!r.excludes(name: ".git")) }
  @Test func backupCreatesSnapshotWithEntries() // sorgente con a.txt, sub/b.txt, .git/HEAD, node_modules/x.js, link → ../a.txt
      // → 1 snapshot; entries contengono "", "a.txt", "sub", "sub/b.txt", ".git", ".git/HEAD", "link"(symlink, linkTarget "../a.txt"); nessuna "node_modules"
  @Test func secondBackupWritesNoNewObjects() // due run identici → report2.newBytes == 0, allObjectHashes invariato
  @Test func identicalFilesStoredOnce() // a.txt e copia.txt con stesso contenuto → 1 oggetto
  @Test func unchangedFileNotReread() // primo run; poi chmod 000 su a.txt senza cambiare mtime/size → secondo run senza warning, hash uguale (preso dalla cache)
  @Test func unreadableFileIsWarning() // nuovo file chmod 000 → report.warnings contiene il suo percorso, snapshot scritto, report.error == nil
  @Test func validateRejectsOverlap() // sorgente = dest o dentro dest o che contiene dest → .sourceOverlapsDestination
  @Test func missingSourceThrows() // run con sorgente inesistente → .sourceMissing
  @Test func cancelledLeavesNoSnapshot() // isCancelled = { true } → lancia .cancelled, snapshotIDs() vuoto
  ```

- [x] **Step 2: Run** `swift test --filter BackupEngineTests` → FAIL.

- [x] **Step 3: Implementa.** Note:
  - `ExcludeRules.excludes` = `fnmatch(pattern, name, 0) == 0` per un pattern qualsiasi.
  - La scansione usa `FileManager.enumerator(at:includingPropertiesForKeys:options:)` senza seguire symlink; i metadati (inode, size, mtime, mode, tipo) vengono da `lstat`. Una cartella esclusa viene saltata con `skipDescendants()`.
  - Per ogni file: hash dalla cache; se manca, leggi `Data(contentsOf:options: .mappedIfSafe)`, calcola l'hash, poi rifai `lstat`. Se size o mtime sono cambiati, riprova una volta; poi aggiungi un avviso e salta il file. Se `!hasObject` → `putObject`. *shortcut: il file intero viene caricato in memoria (mappato); file di molti GB → passare alla lettura a blocchi.*
  - Errori di lettura su un singolo file → avviso `"<percorso>: <descrizione>"`, non lancia.
  - Tutto il run sta dentro `repository.withLock`. Il manifest si scrive per ultimo; `isCancelled` va controllato a ogni file. `cache.save()` dopo il manifest.
  - Progresso = file elaborati / file contati in una prima passata di sola enumerazione.

- [x] **Step 4: Run** `swift test --filter BackupEngineTests` → PASS.

- [x] **Step 5: Commit** `git commit -am "feat(core): motore di backup con esclusioni e cache degli hash"` (aggiungi prima i file nuovi).

---

### Task 3: Retention e pianificazione (logica pura)

**Files:**
- Create: `Sources/BackupCore/Retention.swift`
- Create: `Sources/BackupCore/Schedule.swift`
- Test: `Tests/BackupCoreTests/RetentionTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct RetentionPolicy: Codable, Equatable { public var days = 14; public var weeks = 8; public var months = 12; public init() }
  public func snapshotsToKeep(_ snapshots: [(id: String, date: Date)], policy: RetentionPolicy, now: Date, calendar: Calendar) -> Set<String>
  public func isBackupDue(lastSuccess: Date?, intervalHours: Int, now: Date) -> Bool
  ```

- [x] **Step 1: Scrivi i test che falliscono** (calendario gregoriano, fuso `Europe/Rome`, `firstWeekday = 2`; `now` = 2026-11-05 12:00):
  ```swift
  @Test func keepsAllWithin24h() // snapshot ogni ora per le ultime 24 h → tutti tenuti
  @Test func keepsLastPerDay() // 3 snapshot il 2026-11-01 (09, 13, 18) → tenuto solo quello delle 18
  @Test func dropsDailyBeyondNDays() // policy.days = 2, weeks = 0, months = 0: vedi asserzione sotto
  @Test func keepsLastPerWeek() // days = 0, weeks = 2: snapshot lun 26 ott e ven 30 ott → tenuto solo ven 30 ott
  @Test func keepsLastPerMonth() // days = 0, weeks = 0, months = 3: 1 e 20 set, 15 ago, 10 lug → tenuti 20 set e 15 ago (settembre, agosto); luglio fuori
  @Test func alwaysKeepsNewest() // policy tutto a 0, unico snapshot di un anno fa → tenuto
  @Test func dueLogic() { #expect(isBackupDue(lastSuccess: nil, intervalHours: 1, now: n))
      #expect(!isBackupDue(lastSuccess: n.addingTimeInterval(-1800), intervalHours: 1, now: n))
      #expect(isBackupDue(lastSuccess: n.addingTimeInterval(-3600), intervalHours: 1, now: n)) }
  ```
  Nel test `dropsDailyBeyondNDays` scrivi l'asserzione esatta: con `days = 2` le finestre giornaliere sono oggi (5 nov) e ieri (4 nov). Snapshot del 4 nov alle 18 e del 1 nov alle 18, entrambi oltre le 24 h, e uno del 5 nov alle 11 → tenuti 5 nov e 4 nov, scartato 1 nov.

- [x] **Step 2: Run** `swift test --filter RetentionTests` → FAIL.

- [x] **Step 3: Implementa `snapshotsToKeep`:**
  ```
  keep = {id con date più recente} ∪ {id con now - date < 24h}
  per (componente, N) in [(.day, days), (.weekOfYear, weeks), (.month, months)] con N > 0:
      periodi = gli N intervalli `calendar.dateInterval(of: componente, for:)` a partire da quello che contiene now, andando indietro
      per ogni periodo: aggiungi a keep l'id con la data massima che cade nel periodo
  ```
  `isBackupDue` = `lastSuccess == nil || now - lastSuccess >= intervalHours * 3600`.

- [x] **Step 4: Run** `swift test --filter RetentionTests` → PASS.

- [x] **Step 5: Commit** `git commit -m "feat(core): retention giornaliera/settimanale/mensile e calcolo scadenza"`

---

### Task 4: Pulizia e tetto del pool

**Files:**
- Create: `Sources/BackupCore/Pruner.swift`
- Test: `Tests/BackupCoreTests/PrunerTests.swift`

**Interfaces:**
- Consumes: `Repository` (Task 1), `snapshotsToKeep`, `RetentionPolicy` (Task 3), `BackupEngine` per preparare i dati nei test (Task 2).
- Produces:
  ```swift
  public struct PruneResult: Equatable { public var deletedSnapshots: [String]; public var deletedObjects: Int; public var poolSize: Int64; public var overCap: Bool }
  public func prune(repository: Repository, policy: RetentionPolicy, capBytes: Int64?, now: Date, calendar: Calendar = .current) throws -> PruneResult
  ```

- [x] **Step 1: Scrivi i test che falliscono:**
  ```swift
  @Test func deletesExpiredSnapshotsAndTheirObjects() // 2 backup con contenuti diversi a date distanti; policy che tiene solo il recente → il vecchio snapshot e l'oggetto usato solo da lui vengono eliminati; quello condiviso resta
  @Test func orphanObjectsFromInterruptedBackupRemoved() // putObject senza manifest + file .tmp → prune li elimina entrambi
  @Test func capDeletesOldestUntilUnder() // 3 snapshot con 1 MB unico ciascuno, cap 2.5 MB → resta solo/i i più recenti finché poolSize <= cap; overCap == false
  @Test func capNeverDeletesNewest() // cap 1 byte → resta 1 snapshot (il più recente), overCap == true
  ```
  I dati di test (file casuali da 1 MB) si creano con `BackupEngine.run` usando un `now` diverso per ogni run.

- [x] **Step 2: Run** `swift test --filter PrunerTests` → FAIL.

- [x] **Step 3: Implementa `prune`:** dentro `withLock`: elimina gli snapshot non tenuti da `snapshotsToKeep`; poi la GC, cioè raggiungibili = unione degli hash di tutti i manifest rimasti, e si eliminano gli oggetti in `allObjectHashes()` non raggiungibili, più `removeTemporaryFiles()`; poi, se `capBytes != nil` e `poolSize > cap` e ci sono più snapshot, elimina il più vecchio, rifai la GC e ripeti. `overCap = poolSize > cap` alla fine.

- [x] **Step 4: Run** `swift test --filter PrunerTests` → PASS.

- [x] **Step 5: Commit** `git commit -m "feat(core): pulizia oggetti orfani e tetto del pool"`

---

### Task 5: Ripristino

**Files:**
- Create: `Sources/BackupCore/Restorer.swift`
- Test: `Tests/BackupCoreTests/RestorerTests.swift`

**Interfaces:**
- Consumes: `Repository`, `Snapshot`, `Entry` (Task 1), `BackupEngine` per i dati di test (Task 2).
- Produces:
  ```swift
  public enum RestoreMode: Equatable { case besideOriginal, replace, into(URL) }
  public enum EntryStatus: Equatable { case unchanged, modified, missing }
  public final class Restorer {
      public init(repository: Repository, trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) })
      @discardableResult
      public func restore(_ snapshot: Snapshot, source: String, path: String, mode: RestoreMode, now: Date = Date()) throws -> URL
      public func versions(source: String, path: String) throws -> [(snapshotID: String, entry: Entry)]  // una per hash distinto, dalla più recente
      public static func restoredName(_ name: String, date: Date) -> String
      public static func status(of entry: Entry) -> EntryStatus   // confronta con il disco: kind/size/mtime(/linkTarget)
  }
  ```

- [x] **Step 1: Scrivi i test che falliscono** (`trash` iniettato: sposta in una cartella temporanea, così i test non toccano il Cestino vero):
  ```swift
  @Test func restoredNameFormat() { let d = /* 2026-11-05 10:00 Europe/Rome */
      #expect(Restorer.restoredName("README.md", date: d) == "README (ripristinato 5 nov 10.00).md")
      #expect(Restorer.restoredName(".env", date: d) == ".env (ripristinato 5 nov 10.00)")
      #expect(Restorer.restoredName("app-web", date: d) == "app-web (ripristinato 5 nov 10.00)") }
  @Test func roundTripWholeSourceInto() // sorgente con: "spazi e àccénti 🎉.txt", file vuoto, cartella vuota, symlink rotto → "nessuno", file chmod 0755, cartella chmod 0555 con un file dentro
      // backup → restore(path: "", mode: .into(tmpDest)) → stesso albero: contenuti byte per byte, permessi, mtime (±0.001 s), linkTarget
  @Test func besideOriginalNeverOverwrites() // modifica a.txt dopo il backup → restore a.txt .besideOriginal → a.txt invariato, accanto "a (ripristinato …).txt" con il vecchio contenuto
  @Test func replaceTrashesCurrent() // restore della sorgente con .replace → la versione attuale passata al trash iniettato, la sorgente ha i contenuti del backup
  @Test func corruptObjectFailsRestore() // corrompi un oggetto → restore lancia .corruptObject
  @Test func versionsDistinctByHash() // 3 backup: v1, v1, v2 di a.txt → versions restituisce 2 elementi, il primo è v2
  @Test func statusDetection() // file invariato → .unchanged; modificato → .modified; cancellato → .missing
  ```

- [x] **Step 2: Run** `swift test --filter RestorerTests` → FAIL.

- [x] **Step 3: Implementa.** Note:
  - Le voci da ripristinare sono quelle con `source` uguale e `path` uguale oppure che inizia con `path + "/"`.
  - Destinazione: `.besideOriginal` → stessa cartella dell'originale con `restoredName` (data = `snapshot.date`); `.replace` → `trash` sull'originale se esiste, poi scrive al suo posto; `.into(dir)` → `dir/<ultimo componente>`.
  - Ordine di scrittura: prima le cartelle (permessi temporanei 0700), poi file e symlink, poi permessi e mtime delle cartelle dalla più profonda alla più superficiale.
  - `readObject` verifica già l'hash; dopo la scrittura imposta `mode` e `mtime` con `FileManager.setAttributes` (per i symlink usa `lchmod`/`lutimes`, oppure ignora mode e mtime).
  - `restoredName` usa un `DateFormatter` con `locale it_IT`, `dateFormat "d MMM HH.mm"`, fuso corrente; estensione = `(name as NSString).pathExtension`.

- [x] **Step 4: Run** `swift test --filter RestorerTests` → PASS; poi `swift test` tutto → PASS.

- [x] **Step 5: Commit** `git commit -m "feat(core): ripristino senza sovrascrittura, versioni e stato file"`

---

### Task 6: App da barra dei menu, pianificatore e build

**Files:**
- Create: `Resources/Info.plist`
- Create: `scripts/build-app.sh`
- Create: `Sources/BackupMe/BackupMeApp.swift` (sostituisce lo stub del Task 1)
- Create: `Sources/BackupMe/Settings.swift`
- Create: `Sources/BackupMe/AppModel.swift`
- Create: `Sources/BackupMe/SystemServices.swift` (notifiche, login item)
- Test: verifica manuale (la logica testabile è già in `BackupCore`)

**Interfaces:**
- Consumes: tutto `BackupCore`.
- Produces (usato dai Task 7–8):
  ```swift
  struct AppSettings: Codable, Equatable {
      var sources: [String] = []; var destination: String? = nil; var intervalHours = 1
      var retention = RetentionPolicy(); var capGB: Double? = nil
      var excludes = ExcludeRules.defaults; var paused = false
      static func load() -> AppSettings; func save()   // UserDefaults, chiave "settings", JSON
  }
  enum BackupStatus: Equatable { case idle, running(Double), failed(String) }
  @MainActor @Observable final class AppModel {
      var settings: AppSettings { didSet { settings.save() } }
      var status: BackupStatus; var history: [BackupReport]   // ultime 50, in Application Support/BackupMe/history.json
      var lastSuccess: Date? { get }
      func backupNow(); func cancelBackup()
      func repository(computer: String? = nil) throws -> Repository   // computer nil = questo Mac
  }
  ```

- [x] **Step 1: Crea `Resources/Info.plist`** con `CFBundleIdentifier` `com.vale76p.BackupMe`, `CFBundleExecutable` `BackupMe`, `CFBundleName` `BackupMe`, `CFBundlePackageType` `APPL`, `CFBundleShortVersionString` `0.1.0`, `CFBundleVersion` `1`, `LSUIElement` true, `LSMinimumSystemVersion` `14.0`.

- [x] **Step 2: Crea `scripts/build-app.sh`** (`set -euo pipefail`): `swift build -c release --product BackupMe`; ricrea `build/BackupMe.app/Contents/{MacOS,Resources}`; copia l'eseguibile e `Info.plist`; `codesign --force --sign - build/BackupMe.app`; con `--install` sostituisce `~/Applications/BackupMe.app` (crea `~/Applications` se manca; prima chiude l'app con `pkill -x BackupMe || true`). Aggiungi `build/` al `.gitignore`.

- [x] **Step 3: Implementa `AppModel`:**
  - Il backup gira in un `Task.detached(priority: .utility)`, che crea `Repository`, `HashCache` (`Application Support/BackupMe/hashcache-<computer>.json`) e `BackupEngine`, esegue `run`, poi `prune` con `capBytes = capGB * 1e9`. Status e history si aggiornano sul main actor. Un solo backup alla volta; `cancelBackup` imposta il flag letto da `isCancelled`.
  - Pianificatore: un `Timer` ogni 60 s chiama `backupNow()` se `!paused && isBackupDue(...)`; all'avvio fa lo stesso controllo; su `NSWorkspace.didWakeNotification` lo ripete dopo 60 s.
  - Destinazione mancante o sorgenti invalide (`BackupEngine.validate`) → `.failed("Destinazione non trovata: …")`, e notifica.

- [x] **Step 4: Implementa `SystemServices.swift`:**
  - `notify(title:body:)` tramite `UNUserNotificationCenter`, con permesso chiesto al primo avvio. Si notifica in tre casi: errore di un backup; `overCap` ("Il tetto è troppo basso per le cartelle selezionate"); nessun backup riuscito da 3 giorni, al massimo una volta al giorno.
  - `setLaunchAtLogin(_ on: Bool) throws` usa `SMAppService.mainApp.register()/unregister()`. Se fallisce, scrive o rimuove `~/Library/LaunchAgents/com.vale76p.BackupMe.plist` (`ProgramArguments` = percorso dell'eseguibile nel bundle, `RunAtLoad` true) e lo carica o scarica con `launchctl bootstrap|bootout gui/$UID`.

- [x] **Step 5: Implementa `BackupMeApp.swift`:** `MenuBarExtra` con icona di sistema (`externaldrive` a riposo, `arrow.triangle.2.circlepath` in corso, `exclamationmark.triangle` in caso di errore), stile `.menu`. Voci:
  - riga di stato: "Ultimo backup: oggi 10:00" / "Backup in corso… 42%" / "Errore: …"
  - "Esegui backup ora" (diventa "Interrompi backup" durante l'esecuzione)
  - "Sfoglia backup…" e "Impostazioni…": aprono le scene `Window` con id `restore` e `settings` (per ora vuote) tramite `openWindow` e `NSApp.activate`
  - "Sospendi backup" / "Riprendi backup"
  - "Esci"

- [ ] **Step 6: Verifica:** *(Non registrata: nessun esito scritto nel repository. Si rifà sulla rc1 in [#24](https://github.com/vale76p/BackupMe/issues/24).)* `scripts/build-app.sh --install && open ~/Applications/BackupMe.app` → l'icona compare nella barra dei menu e il menu mostra le voci. Con le impostazioni vuote "Esegui backup ora" mostra un errore chiaro e non va in crash. `codesign -dv ~/Applications/BackupMe.app` → `Signature=adhoc`.

- [x] **Step 7: Commit** `git commit -m "feat(app): barra dei menu, pianificatore, notifiche, build locale"`

---

### Task 7: Finestra Impostazioni

**Files:**
- Create: `Sources/BackupMe/SettingsView.swift`
- Modify: `Sources/BackupMe/BackupMeApp.swift` (scena `settings`)

**Interfaces:**
- Consumes: `AppModel`, `AppSettings` (Task 6); `BackupEngine.validate`, `Repository.poolSize`, `snapshotIDs` (Task 1–2); `setLaunchAtLogin` (Task 6).

- [x] **Step 1: Implementa `SettingsView`** (`Form`, testi in italiano):
  - **Cartelle**: lista con +/− (`NSOpenPanel`, solo cartelle, selezione multipla). Una sorgente rifiutata da `validate` mostra l'errore e non viene aggiunta.
  - **Destinazione**: percorso + "Scegli…". Se non è impostata, suggerisce il primo `~/Library/CloudStorage/OneDrive-*` trovato, con un pulsante "Usa OneDrive".
  - **Frequenza**: `Picker` 1/2/4/6/12/24 ore.
  - **Conservazione**: tre `Stepper` per giorni (0–90), settimane (0–52), mesi (0–120).
  - **Tetto pool**: `Toggle` "Limita spazio" + campo GB.
  - **Esclusioni**: `TextEditor`, un pattern per riga, con "Ripristina predefinite".
  - **Avvio al login**: `Toggle`; un errore viene mostrato sotto il toggle.
  - In fondo: "Spazio occupato: X GB · N backup", calcolato in background all'apertura.

- [ ] **Step 2: Verifica manuale:** *(Non registrata: nessun esito scritto nel repository. Si rifà sulla rc1 in [#24](https://github.com/vale76p/BackupMe/issues/24).)* imposta come sorgente una cartella progetto di prova e come destinazione una cartella in `/private/tmp`. "Esegui backup ora" → lo stato diventa "Ultimo backup: oggi HH:MM" e nella destinazione compaiono `BackupMe/<Mac>/snapshots/*.json.lzfse`. Chiudi e riapri l'app → le impostazioni sono rimaste. Prova ad aggiungere come sorgente la destinazione stessa → rifiutata.

- [x] **Step 3: Commit** `git commit -m "feat(app): finestra impostazioni"`

---

### Task 8: Finestra di ripristino (layout B)

**Files:**
- Create: `Sources/BackupMe/RestoreView.swift`
- Create: `Sources/BackupMe/RestoreModel.swift`
- Modify: `Sources/BackupMe/BackupMeApp.swift` (scena `restore`)

**Interfaces:**
- Consumes: `AppModel.repository(computer:)`, `Repository.computers(in:)`, `snapshotIDs`, `readSnapshot` (Task 1); `Restorer` (Task 5).
- Produces:
  ```swift
  @MainActor @Observable final class RestoreModel {
      var computer: String; var source: String?; var snapshots: [(id: String, date: Date)]
      var selected: Snapshot?; var currentPath: String   // "" = radice della sorgente
      var search: String
      func children() -> [Entry]                         // figli diretti di currentPath in selected
      func searchResults() -> [(snapshotID: String, entry: Entry)]   // nome che contiene search (case-insensitive), in tutti gli snapshot caricati
  }
  ```

- [x] **Step 1: Implementa `RestoreModel`.** I manifest si caricano in background, uno alla volta; si tengono in cache solo quelli già aperti, e la ricerca carica il resto con un indicatore di avanzamento.

- [x] **Step 2: Implementa `RestoreView`** con `NavigationSplitView`:
  - **Toolbar**: picker Computer (solo se ce n'è più di uno), picker Cartella sorgente, campo di ricerca.
  - **Sidebar**: backup raggruppati in "Oggi", "Ieri", "Settimana scorsa" (ultimi 7 giorni), "Mesi precedenti", con l'ora o la data secondo il gruppo.
  - **Dettaglio**: breadcrumb del percorso; lista con icona, nome, dimensione, data ed etichetta da `Restorer.status` ("modificato" / "non più presente oggi"). Doppio clic su una cartella per entrarci. Durante una ricerca mostra i risultati con la data del backup.
  - **Pulsanti in basso**:
    - "Mostra versioni del file": un foglio con `versions(...)`, ogni riga ripristinabile;
    - "Ripristina in…": `NSOpenPanel` per scegliere la cartella, poi `.into`;
    - "Ripristina": `.besideOriginal` per file e sottocartelle. Per la sorgente intera apre un dialogo con "Sostituisci" (`.replace`, con il testo "La versione attuale verrà spostata nel Cestino"), "Ripristina in…" e "Annulla".
  - Alla fine mostra in Finder il risultato (`NSWorkspace.activateFileViewerSelecting`); gli errori compaiono in un alert.

- [ ] **Step 3: Verifica manuale** *(Non registrata: nessun esito scritto nel repository. Si rifà sulla rc1 in [#24](https://github.com/vale76p/BackupMe/issues/24).)* con la configurazione del Task 7:
  1. Modifica un file e cancellane un altro nel progetto di prova, poi fai un secondo backup.
  2. In "Sfoglia backup…" il primo backup mostra il file modificato con "modificato" e quello cancellato con "non più presente oggi".
  3. "Ripristina" sul file cancellato → `nome (ripristinato …)` accanto all'originale, contenuto corretto.
  4. La ricerca per nome trova il file in entrambi i backup.
  5. "Mostra versioni" sul file modificato → 2 versioni.
  6. Ripristino della sorgente intera con "Sostituisci" → la versione attuale finisce nel Cestino.

- [x] **Step 4: Commit** `git commit -m "feat(app): finestra di ripristino"`

---

### Task 9: Prova reale su OneDrive e README

**Files:**
- Modify: `README.md`

- [x] **Step 1: Scrivi `README.md`** con:
  - requisiti: macOS 14+, Xcode o Command Line Tools;
  - build e installazione: `scripts/build-app.sh --install`;
  - primo avvio: permessi per cartelle e notifiche, scelta di sorgenti e destinazione;
  - dove sono i backup su OneDrive e come recuperarli da un altro Mac;
  - disinstallazione: chiudere l'app, rimuovere `~/Applications/BackupMe.app`, `~/Library/Application Support/BackupMe`, l'eventuale LaunchAgent; i backup su OneDrive restano.

- [ ] **Step 2: Prova reale:** *(Non registrata: nessun esito scritto nel repository. Si rifà sulla rc1 in [#24](https://github.com/vale76p/BackupMe/issues/24).)* backup di una cartella progetto vera (con `.git` e `node_modules`) verso `~/Library/CloudStorage/OneDrive-…`.
  - Dopo la sincronizzazione i file compaiono nel web di OneDrive sotto `BackupMe/<Mac>/`, e `node_modules` non è nell'archivio.
  - Un secondo backup senza modifiche dura pochi secondi e non scrive oggetti nuovi (`newBytes == 0` nello storico).
  - Il ripristino di un file e di una cartella funziona.
  - Dopo un logout e un nuovo login, l'app si riavvia da sola.

- [x] **Step 3: Commit e push** `git commit -am "docs: README di installazione e uso" && git push`
