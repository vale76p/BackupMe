# BackupMe — contenitori (formato 2): piano di implementazione

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** I file piccoli dell'archivio finiscono in pochi contenitori grandi, e BackupMe non elimina mai più di 50 file all'ora dalla destinazione, così l'email di OneDrive sulle eliminazioni in massa non arriva più.

**Architecture:** Un oggetto sta in un file suo (come oggi) o dentro un contenitore `packs/<id>.pack` con il suo indice `packs/<id>.idx`; chi legge cerca in entrambi. La raccolta giornaliera scrive in locale l'elenco degli oggetti non più usati (i *condannati*); ogni backup ne elimina un pezzo dentro un tetto orario, compatta i contenitori e converte i file piccoli esistenti. Conversione e compattazione non hanno stato proprio: copiano gli oggetti in un contenitore con id più alto, e la copia vecchia diventa da sola un doppione eliminabile.

**Tech Stack:** Swift 6, Foundation, CryptoKit, LZFSE di Foundation, Swift Testing, JavaScript for Automation per il kit. Nessuna dipendenza.

**Spec:** `docs/superpowers/specs/2026-11-12-contenitori-design.md`

## Global Constraints

- macOS 14, nessuna dipendenza, nucleo in `Sources/BackupCore` provato senza l'app.
- Tetto alle eliminazioni: 50 file negli ultimi 60 minuti, su manifest, oggetti singoli, contenitori e indici. Chiave delle preferenze `deletionsPerHour`.
- Soglia di scrittura: forma salvata sotto 4 MiB nel contenitore (`Repository.packThreshold = 4 << 20`). Contenitore chiuso a circa 32 MiB (`Repository.packTarget = 32 << 20`).
- Contenitori e indici sono immutabili, scritti con `Repository.publish` (`.tmp`, `fsync`, rinomina, mai attraverso un collegamento).
- Il manifest resta l'ultima scrittura di un backup.
- Il kit usa solo JavaScript for Automation e `/usr/bin/shasum`.
- Mai eliminare cronologia per fare posto a doppioni o a byte non più usati.
- Un backup orario non legge i riferimenti di tutti i manifest: solo quelli comparsi dopo l'ultima raccolta.
- `Repository(destination:computerName:)` senza `packBelow` scrive oggetti singoli come oggi: i 231 test esistenti non cambiano e restano verdi. Solo l'app (Task 9) accende i contenitori.
- Messaggi all'utente in italiano; commenti nel codice in inglese, una riga, solo il perché.
- Nomi dei file fissi: contenitore `<16 cifre esadecimali minuscole>.pack`, indice con lo stesso nome e `.idx`.

## Review Focus

1. **Contenitore non leggibile (solo online senza rete, permessi):** è «non letto», mai «danneggiato»; niente viene riparato, riscritto o eliminato per questo. Test nel Task 5.
2. **Indice con checksum valido ma posizioni sbagliate** (manomesso, o di un altro contenitore): la lettura se ne accorge dall'intestazione del record e ricostruisce l'indice dal contenitore. Test nel Task 2.
3. **Destinazione exFAT o FAT32** (niente `RENAME_EXCL`, niente `flock`): pubblicare e leggere un contenitore funziona. Test nel Task 2.
4. **File vuoti e migliaia di oggetti minuscoli in un contenitore:** un oggetto di lunghezza 0 si salva, si legge e si ripristina dall'app e dal kit. Test nei Task 1 e 4.
5. **Orologio spostato indietro o avanti:** gli id dei contenitori restano crescenti e il tetto orario non si azzera. Test nei Task 2 e 6.

## File

| File | Responsabilità |
|---|---|
| `Sources/BackupCore/Pack.swift` (nuovo) | Codifica di contenitore e indice, senza I/O |
| `Sources/BackupCore/RepositoryPacks.swift` (nuovo) | `extension Repository`: scrivere, leggere, elencare, eliminare contenitori |
| `Sources/BackupCore/Repository.swift` | `packBelow`, formato 2, letture che cercano in entrambe le forme |
| `Sources/BackupCore/DeletionLedger.swift` (nuovo) | Conto delle eliminazioni nell'ultima ora |
| `Sources/BackupCore/PackMaintenance.swift` (nuovo) | Piano locale, condannati, compattazione, conversione |
| `Sources/BackupCore/Pruner.swift` | `prune` con il tetto, chiama `PackMaintenance` |
| `Sources/BackupCore/BackupEngine.swift`, `Verify.swift`, `RestoreKit.swift` | Chiudere il contenitore prima del manifest; verifica; kit 10 |
| `Sources/BackupMe/AppModel.swift`, `SettingsView.swift` | Accendere i contenitori, tetto orario, Registro, riga in Destinazione |

---

### Task 0: Ramo e modifiche già fatte

**Files:** `Sources/BackupMe/AppModel.swift`, `Sources/BackupCore/Pruner.swift`, `Tests/BackupCoreTests/PrunerTests.swift`, i due documenti di questo progetto.

- [ ] **Step 1:** `git switch -c contenitori`
- [ ] **Step 2:** `swift test 2>&1 | tail -3` — atteso: `Test run with 231 tests in 22 suites passed`.
- [ ] **Step 3: Commit** delle modifiche del 2026-11-12 (pulizia non più forzata dopo un backup fallito, riga info nel Registro, test) e di spec e piano:

```bash
git add Sources/BackupMe/AppModel.swift Sources/BackupCore/Pruner.swift Tests/BackupCoreTests/PrunerTests.swift docs/superpowers
git commit -m "fix: la pulizia non cancella più i file di un backup fallito; spec e piano dei contenitori"
```

---

### Task 1: Codifica di contenitore e indice

**Files:**
- Create: `Sources/BackupCore/Pack.swift`
- Modify: `Sources/BackupCore/Repository.swift:6-16` (aggiungere `case damagedPack(String)` a `RepositoryError`)
- Test: `Tests/BackupCoreTests/PackTests.swift`

**Interfaces — Produces:**

```swift
public struct PackEntry: Equatable, Sendable {
    public var hash: String      // SHA-256 of the original content
    public var offset: Int       // of the stored bytes, after the record header
    public var length: Int       // of the stored bytes
    public var compressed: Bool  // LZFSE, as a `.lzfse` object; false as a `.raw` one
}
enum Pack {
    static let magic = Data("BMPACK1\n".utf8)
    static let headerSize = 37   // 32 hash bytes, 1 encoding byte (0 raw, 1 lzfse), 4 length bytes big-endian
    static func append(_ body: Data, hash: String, compressed: Bool, to pack: inout Data) -> PackEntry
    static func scan(_ pack: Data, id: String) throws -> [PackEntry]        // throws .damagedPack(id)
    static func encodeIndex(_ entries: [PackEntry]) -> Data
    static func decodeIndex(_ data: Data, id: String) throws -> [PackEntry] // throws .damagedPack(id)
}
```

Formato, da riportare identico in `docs/formato-archivio.md` (Task 10):

- **Contenitore:** `BMPACK1\n`, poi i record uno dopo l'altro: intestazione di 37 byte e i byte dell'oggetto, gli stessi che avrebbe come file `.lzfse` o `.raw`. `append` su un `Data` vuoto scrive prima `magic`.
- **Indice:** LZFSE di `<64 cifre esadecimali>\n<corpo>`, dove le cifre sono lo SHA-256 del corpo e il corpo è JSON senza spazi `[["<hash>",<offset>,<length>,<0|1>],…]` in ordine di offset.

- [ ] **Step 1: Test che falliscono** in `PackTests`:

```swift
@Test func recordsRoundTripThroughScanAndIndex() throws {
    var pack = Data()
    let a = Data("ciao".utf8), empty = Data()
    let e1 = Pack.append(a, hash: sha256Hex(a), compressed: false, to: &pack)
    let e2 = Pack.append(empty, hash: sha256Hex(empty), compressed: false, to: &pack)
    #expect(pack.prefix(8) == Pack.magic)
    #expect(e1.offset == 8 + Pack.headerSize && e1.length == 4)
    #expect(e2.offset == e1.offset + 4 + Pack.headerSize && e2.length == 0)
    #expect(try Pack.scan(pack, id: "x") == [e1, e2])
    #expect(try Pack.decodeIndex(Pack.encodeIndex([e1, e2]), id: "x") == [e1, e2])
}
@Test func truncatedPackAndDamagedIndexAreRefused() {
    var pack = Data()
    _ = Pack.append(Data("ciao".utf8), hash: sha256Hex(Data("ciao".utf8)), compressed: false, to: &pack)
    #expect(throws: RepositoryError.damagedPack("x")) { try Pack.scan(pack.dropLast(1), id: "x") }
    #expect(throws: RepositoryError.damagedPack("x")) { try Pack.scan(Data("altro".utf8), id: "x") }
    var index = Pack.encodeIndex([])
    index[index.count / 2] ^= 0xff
    #expect(throws: RepositoryError.damagedPack("x")) { try Pack.decodeIndex(index, id: "x") }
}
@Test func indexBytesMatchTheFormatDocument() throws {
    let h = String(repeating: "ab", count: 32)
    let text = String(decoding: try (Pack.encodeIndex([PackEntry(hash: h, offset: 45, length: 3, compressed: true)]) as NSData)
        .decompressed(using: .lzfse) as Data, as: UTF8.self)
    let body = "[[\"\(h)\",45,3,1]]"
    #expect(text == sha256Hex(Data(body.utf8)) + "\n" + body)
}
```

- [ ] **Step 2:** `swift test --filter PackTests` — atteso: non compila (`Pack` non esiste).
- [ ] **Step 3: Implementare `Pack`.** Un hash che non è `Repository.isHash`, un offset o una lunghezza fuori dal contenitore valgono come danno.
- [ ] **Step 4:** `swift test --filter PackTests` — atteso: 3 test passati.
- [ ] **Step 5: Commit** `feat(core): codifica dei contenitori e del loro indice`

---

### Task 2: L'archivio scrive e legge i contenitori

**Files:**
- Create: `Sources/BackupCore/RepositoryPacks.swift`
- Modify: `Sources/BackupCore/Repository.swift` — `init`, `format`, `putObject`, `readObject`, `verifyObject`, `repairObject`, `restoreObject`, `hasObject`, `objectSizes`, `allObjectHashes`, `poolSize`, `removeTemporaryFiles`. Da `private` a interno ciò che l'estensione usa: `knownObjects`, `parentDirectory(of:)`, `archiveDirectory(create:)`, `fm`.
- Test: `Tests/BackupCoreTests/RepositoryPackTests.swift`

**Interfaces — Consumes:** `Pack`, `PackEntry` (Task 1).

**Interfaces — Produces:**

```swift
public static let format = 2
public static let packThreshold = 4 << 20, packTarget = 32 << 20
public init(destination: URL, computerName: String, create: Bool = true, packBelow: Int = 0) throws
/// Hashes `hasObject` answers false for: scheduled for deletion, never reused by a new backup.
public var condemned: Set<String> = []
public func flushPack() throws                       // publishes the open container and its index; nothing when empty
public func packIDs() throws -> [String]             // ascending
public func packEntries(_ id: String) throws -> [PackEntry]
public func packSize(_ id: String) -> Int64          // container plus index, on disk
public func deletePack(_ id: String) throws          // index first, then container
public func looseObjectSizes() throws -> [String: Int64]
/// The container holding the copy that counts: the one with the greatest id.
func packOf(_ hash: String) -> String?
/// Copies these objects into new containers, whatever form they have now. Each is read and verified first;
/// one that doesn't verify throws `corruptObject` before anything is written for it.
public func repack(_ hashes: [String]) throws
```

Decisioni:

- **`packBelow`** è il solo interruttore: `putObject` mette nel contenitore aperto un oggetto la cui forma salvata è più piccola di `packBelow`, gli altri in un file come oggi. `0` non mette mai niente in un contenitore.
- **Contenitore aperto** in memoria (`Data` più le voci). Si pubblica a `packTarget` e con `flushPack()`. Ordine: contenitore, poi indice.
- **Id:** `String(format: "%016llx", max(ultimo + 1, millisecondi dal 1970))`, dove `ultimo` è l'id più alto presente (0 se nessuno). Strettamente crescente anche con l'orologio indietro.
- **Formato 2:** prima della prima pubblicazione `flushPack` riscrive `repo.json` con `"format": 2` (come fa `claim(owner:)`, chiavi ordinate). Se `repo.json` non si può leggere o riscrivere, `flushPack` lancia: un archivio con contenitori marcato 1 verrebbe ripristinato a metà dal kit vecchio.
- **Indice in memoria:** caricato alla prima domanda, dagli `.idx` di `packIDs()` in ordine crescente, così l'id più alto vince. Un `.idx` mancante, danneggiato, o la cui prima voce non combacia con l'intestazione del record nel contenitore si ricostruisce con `Pack.scan` e si riscrive. `// shortcut: every index is read at each opening, a local cache when a million objects make it slow`
- **Lettura** (`readObject`, e con lui `verifyObject` e `restoreObject`): prima il file singolo; se manca o non si verifica, la copia nel contenitore con l'id più alto; se nemmeno quella si verifica, le altre copie cercando in tutti gli indici. Vale la prima che si verifica. Tutto fallito con almeno una copia letta: `corruptObject`. Una lettura che fallisce (file non raggiungibile) rilancia il suo errore e non vale come danno.
- **`repairObject`:** con una copia singola, come oggi. Con la sola copia nel contenitore, scrive un oggetto singolo dalla sorgente (dopo averne verificato l'hash) e non tocca il contenitore.
- **`hasObject`:** falso per i `condemned`; altrimenti vero se l'oggetto è in un file, in un contenitore pubblicato o in quello aperto.
- **`objectSizes()`** e **`allObjectHashes()`:** oggetti singoli più quelli nei contenitori (dimensione = `length`; con due forme vale il file). `objectSizes(sampleDirs:)` aggiunge gli oggetti di un contenitore a caso. **`poolSize()`:** file singoli, `packSize` di ogni contenitore, manifest.
- **`removeTemporaryFiles`:** anche i `.tmp` in `packs/` e gli `.idx` senza contenitore.
- `packs/` si crea con `childDirectory("packs", in:, create: true)` alla prima pubblicazione; mai attraverso un collegamento.

- [ ] **Step 1: Test che falliscono** in `RepositoryPackTests` (suite con `dest = tmp()`, helper `repo(packBelow:)` e `put(_ r: Repository, _ text: String) -> String` che chiama `putObject` e restituisce l'hash; in `TestSupport.swift` un `extension Repository { var archiveFormat: Int }` che legge `format` da `repo.json`):

```swift
@Test func smallObjectsGoIntoOneContainerAndLargeOnesStayFiles() throws {
    let r = try repo(packBelow: 100)
    let small = try put(r, "piccolo"), empty = try put(r, "")
    let big = Data((0..<4000).map { _ in UInt8.random(in: 0...255) })
    _ = try r.putObject(big, hash: sha256Hex(big))
    try r.flushPack()
    #expect(objectFile(r, small) == nil && objectFile(r, empty) == nil && objectFile(r, sha256Hex(big)) != nil)
    #expect(try r.packIDs().count == 1)
    let again = try repo(packBelow: 100)
    #expect(try again.readObject(small) == Data("piccolo".utf8) && again.readObject(empty).isEmpty)
    #expect(again.hasObject(small) && again.archiveFormat == 2)   // archiveFormat: test helper reading repo.json
    #expect(try again.allObjectHashes() == [small, empty, sha256Hex(big)])
}
@Test func withoutPackBelowNothingChanges() throws {
    let r = try repo(packBelow: 0)
    let h = try put(r, "piccolo")
    try r.flushPack()
    #expect(objectFile(r, h) != nil && (try r.packIDs()).isEmpty && r.archiveFormat == 1)
}
@Test func missingOrWrongIndexIsRebuiltFromTheContainer() throws   // delete the .idx; then replace it with the valid index of another container: readObject still returns the data, and the .idx on disk decodes to the scan
@Test func newestCopyCountsAndAnOlderOneRescuesIt() throws          // repack([h]) twice: packOf(h) is the greatest id; flip a byte of its stored bytes: readObject still returns the data
@Test func corruptOnlyCopyIsRepairedAsAFile() throws                // flip the stored byte, repairObject(h, from: source) == true, objectFile(r, h) != nil, the container's bytes unchanged
@Test func condemnedObjectIsNotReusedButStillRead() throws          // r.condemned = [h]: hasObject(h) == false, readObject(h) == data
@Test func idsGrowEvenWhenTheClockGoesBack() throws                 // plant packs/ffffffffffff0000.pack (valid, empty): the next flushPack publishes ffffffffffff0001
@Test func packsFolderSwappedForALinkIsRefused() throws             // packs -> symlink to another folder: flushPack throws and nothing is written through it
@Test func unreadableContainerIsNotCorrupt() throws                 // chmod 000 on the .pack: readObject throws an error that is not RepositoryError.corruptObject
@Test(arguments: ["ExFAT", "MS-DOS"]) func containerOnFATFilesystems(fs: String) throws   // same disk-image harness as RepositoryTests.snapshotOnFATFilesystems(fs:)
```

- [ ] **Step 2:** `swift test --filter RepositoryPackTests` — atteso: non compila.
- [ ] **Step 3: Implementare** secondo le decisioni sopra.
- [ ] **Step 4:** `swift test 2>&1 | tail -3` — atteso: tutti i test passati (i 231 di prima più i nuovi).
- [ ] **Step 5: Commit** `feat(core): l'archivio scrive e legge i contenitori (formato 2)`

---

### Task 3: Il backup chiude il contenitore prima del manifest

**Files:**
- Modify: `Sources/BackupCore/Repository.swift` (`writeSnapshot`), `Sources/BackupCore/BackupEngine.swift:107-110` (`run`)
- Test: `Tests/BackupCoreTests/RepositoryPackTests.swift`

**Interfaces — Consumes:** `flushPack()`, `packBelow` (Task 2).

- `writeSnapshot` chiama `try flushPack()` come prima cosa: un errore lì ferma il backup prima del manifest.
- `BackupEngine.run`, dentro `withLock`, aggiunge `defer { try? repository.flushPack() }`: un backup interrotto, fallito o senza modifiche lascia pubblicato quello che ha copiato.

- [ ] **Step 1: Test che falliscono:**

```swift
@Test func mixedArchiveRestoresBothBackups() throws
// backup 1 with packBelow 0 (files a.txt, b.txt, vuoto.txt), backup 2 with packBelow 4 << 20 after changing a.txt and adding c.txt:
// Restorer restores each snapshot into a new folder and every file equals what was saved; objects/ gained no file in backup 2
@Test func interruptedBackupKeepsWhatItCopied() throws
// 20 files, isCancelled true after the 10th tick: run throws .cancelled, packIDs().count == 1;
// the next run of the same files reports newBytes for 10 files only
```

- [ ] **Step 2:** `swift test --filter RepositoryPackTests` — atteso: i due test falliscono (oggetti non trovati al ripristino).
- [ ] **Step 3: Implementare** le due righe.
- [ ] **Step 4:** `swift test 2>&1 | tail -3` — atteso: tutto passato.
- [ ] **Step 5: Commit** `feat(core): il contenitore si chiude prima del manifest`

---

### Task 4: Kit di ripristino 10

**Files:**
- Modify: `Sources/BackupCore/RestoreKit.swift` (`version = 10`, testo di `LEGGIMI.txt`, il ramo `else` che ripristina un file, righe 311-316)
- Test: `Tests/BackupCoreTests/RestoreKitTests.swift`, `Tests/BackupCoreTests/FormatFixtureTests.swift`

**Interfaces — Consumes:** formato di `.pack` e `.idx` (Task 1).

- Lo script cerca prima `objects/xx/<hash>.lzfse|.raw` come oggi. Solo se mancano, e una volta sola, carica tutti gli `packs/*.idx` in ordine di nome (decompressione LZFSE, la prima riga si salta, `JSON.parse` del resto) in una mappa hash → `[percorso del .pack, offset, length, compresso]`: l'ultimo nome vince.
- Legge l'oggetto con `NSFileHandle.fileHandleForReadingAtPath`, `seekToFileOffset`, `readDataOfLength`; lo decomprime se serve; lo scrive senza sovrascrivere. La verifica con `shasum` che lo script fa già copre anche questi file.
- Un `.idx` che non si decodifica è un problema elencato a fine ripristino, non un arresto: i file che dipendono da lui risultano «non ripristinato».
- `LEGGIMI.txt` nomina `packs/` nella struttura dell'archivio.

- [ ] **Step 1: Test che falliscono:**

```swift
// RestoreKitTests
@Test func kitRestoresAMixedArchive() throws
// the archive of mixedArchiveRestoresBothBackups, plus an empty file inside a container: the installed
// RIPRISTINO.command restores the newest backup with exit status 0 and every file is identical to the source
// FormatFixtureTests
@Test func version9KitRefusesFormat2() throws
// copy("1.0-rc1"), set "format": 2 in repo.json, run the fixture's own RIPRISTINO.command:
// status != 0 and the output contains "formato 2"
```

- [ ] **Step 2:** `swift test --filter "RestoreKitTests|FormatFixtureTests"` — atteso: `kitRestoresAMixedArchive` fallisce con file «non ripristinato»; `version9KitRefusesFormat2` passa già (documenta la garanzia).
- [ ] **Step 3: Implementare** nello script.
- [ ] **Step 4:** `swift test 2>&1 | tail -3` — atteso: tutto passato, compresi `KitTestTests`.
- [ ] **Step 5: Commit** `feat(kit): RIPRISTINO.command versione 10 legge i contenitori`

---

### Task 5: Verifica e controllo dopo l'aggiornamento

**Files:**
- Modify: `Sources/BackupCore/Verify.swift` (`ArchiveCheck`, `checkArchive`, `upgradeCheck`)
- Test: `Tests/BackupCoreTests/VerifyTests.swift`

**Interfaces — Consumes:** `packIDs()`, `packEntries(_:)`, `objectSizes()` (Task 2).

**Interfaces — Produces:** `ArchiveCheck.damagedPacks: [String]` (contenitori che `Pack.scan` rifiuta); `isHealthy` è falso se non è vuoto.

- `checkArchive` passa ogni contenitore con `Pack.scan` e ne ricostruisce l'indice se serve (lo fa già `packEntries`). Gli oggetti nei contenitori sono verificati dal giro che c'è già, perché `objectSizes()` li elenca.
- `upgradeCheck` elenca tra gli estranei ciò che in `packs/` non è `<16 hex>.pack` o `<16 hex>.idx` regolare, come fa per `objects/`.
- La verifica a campione non cambia: `objectSizes(sampleDirs:)` include già un contenitore a caso.

- [ ] **Step 1: Test che falliscono:**

```swift
@Test func checkFindsAndRepairsACorruptObjectInAContainer() throws   // flip a stored byte: objects.repaired == [h] when the source file is unchanged, objects.corrupt == [h] when it is gone
@Test func checkRebuildsAMissingIndex() throws                       // delete the .idx: isHealthy, and the .idx exists again
@Test func truncatedContainerIsReported() throws                     // damagedPacks == [id], !isHealthy
@Test func unreadableContainerFailsTheCheckWithoutCallingItDamaged() throws   // chmod 000: checkArchive throws; nothing is rewritten or deleted
@Test func upgradeCheckReportsStraysInPacks() throws                 // a file "appunti.txt" in packs/: attention contains "packs/appunti.txt"
```

- [ ] **Step 2:** `swift test --filter VerifyTests` — atteso: i cinque falliscono.
- [ ] **Step 3: Implementare.**
- [ ] **Step 4:** `swift test 2>&1 | tail -3` — atteso: tutto passato.
- [ ] **Step 5: Commit** `feat(core): verifica e controllo conoscono i contenitori`

---

### Task 6: Conto delle eliminazioni nell'ultima ora

**Files:**
- Create: `Sources/BackupCore/DeletionLedger.swift`
- Test: `Tests/BackupCoreTests/DeletionLedgerTests.swift`

**Interfaces — Produces:**

```swift
public struct DeletionLedger: Codable, Equatable, Sendable {
    public init()
    /// How many files may be deleted now: `limit` minus those recorded in the 60 minutes before `now`, never below 0.
    public func allowance(limit: Int, now: Date) -> Int
    /// Remembers `count` deletions at `now` and forgets those older than an hour. A count of 0 is not kept.
    public mutating func record(_ count: Int, at now: Date)
}
```

Una registrazione con la data nel futuro (orologio spostato indietro) continua a contare finché non ha più di un'ora rispetto a `now`.

- [ ] **Step 1: Test che falliscono:**

```swift
@Test func allowanceCountsTheLastHour() {
    var l = DeletionLedger()
    let t = Date(timeIntervalSince1970: 1_700_000_000)
    l.record(30, at: t); l.record(15, at: t.addingTimeInterval(900))
    #expect(l.allowance(limit: 50, now: t.addingTimeInterval(1800)) == 5)
    #expect(l.allowance(limit: 50, now: t.addingTimeInterval(3601)) == 35)
    #expect(l.allowance(limit: 50, now: t.addingTimeInterval(4600)) == 50)
    #expect(l.allowance(limit: 10, now: t.addingTimeInterval(60)) == 0)
}
@Test func clockSetBackDoesNotResetTheCount() {
    var l = DeletionLedger()
    let t = Date(timeIntervalSince1970: 1_700_000_000)
    l.record(50, at: t)
    #expect(l.allowance(limit: 50, now: t.addingTimeInterval(-7200)) == 0)
}
@Test func survivesEncoding() throws   // JSONEncoder then JSONDecoder: equal
```

- [ ] **Step 2:** `swift test --filter DeletionLedgerTests` — atteso: non compila.
- [ ] **Step 3: Implementare.**
- [ ] **Step 4:** `swift test --filter DeletionLedgerTests` — atteso: 3 passati.
- [ ] **Step 5: Commit** `feat(core): conto delle eliminazioni nell'ultima ora`

---

### Task 7: Pulizia con il tetto e con i condannati

**Files:**
- Create: `Sources/BackupCore/PackMaintenance.swift`
- Modify: `Sources/BackupCore/Pruner.swift` (`PruneResult`, `prune`, `trackVanished`)
- Test: `Tests/BackupCoreTests/PackMaintenanceTests.swift`

**Interfaces — Consumes:** Task 2.

**Interfaces — Produces:**

```swift
public struct CleanupOptions {
    public init()
    /// Files this call may delete from the destination, of any kind. nil: no limit, as before containers.
    public var maxDeletions: Int? = nil
    /// Move small single-file objects into containers (Task 8).
    public var convert = false
    /// Whether a container can be relied on. nil: `Repository.packIsConfirmed`.
    public var confirmed: ((String) -> Bool)? = nil
}
public func prune(repository:policy:capBytes:now:calendar:refsCache:forceGC:pinned:gcDue:options: CleanupOptions = .init()) throws -> PruneResult
// PruneResult gains:
public var deletedFiles = 0        // manifests, single-file objects, and 2 for each container
public var capPending = false      // the cap loop stopped for the budget, not for lack of backups to delete
/// The hashes the last collection found unused: what a new backup must not reuse. Empty without a plan.
public func condemnedObjects(refsCache: URL) -> Set<String>
extension Repository {
    /// Uploaded, when the cloud client says; where it doesn't, in a cloud folder (`CloudFolder.installed()`) once
    /// the container is an hour old, elsewhere at once.
    public func packIsConfirmed(_ id: String, now: Date) -> Bool
}
```

**Il piano locale.** File `<refsCache>/cleanup`, JSON di `struct CleanupPlan: Codable { var snapshots: [String]; var condemned: [String]; var conversionDone = false }`. `trackVanished` lo ignora come ignora `archive` (oggi due confronti con `"archive"`: diventano un insieme di nomi riservati). `// shortcut: a JSON list of hashes, a binary file like the references cache when the condemned are millions`

**Algoritmo di `prune`**, nell'ordine (la parte prima della raccolta è quella di oggi, con `left`):

```
left = options.maxDeletions ?? .max
1. conservazione: elimina i manifest fuori regola finché left > 0            (left -= 1 ciascuno)
2. tetto allo spazio: come oggi, ma solo finché left > 0; se si ferma per left, capPending = true
3. se la raccolta è dovuta (la condizione di oggi: (!deleted.isEmpty && gcDue) || !fits || forceGC):
       reachable come oggi; plan = (snapshots: ids, condemned: allObjectHashes − reachable, conversionDone di prima)
   altrimenti plan = quello salvato; senza piano si esce senza eliminare oggetti
4. se gcSkipped (backup spariti, i 3 giorni): si esce senza eliminare oggetti né contenitori
5. rete di sicurezza: per ogni id presente che non è in plan.snapshots, plan.condemned −= riferimenti(id)
   se uno non si legge: nessuna eliminazione di oggetti o contenitori in questo giro, senza errore
6. oggetti singoli condannati: deleteObject finché left > 0                    (left -= 1)
7. contenitori morti: nessuna voce è insieme la copia che conta (packOf(hash) == id) e non condannata
       deletePack se left >= 2 e se è confermato ogni contenitore che tiene la copia che conta
       di una sua voce non condannata                                           (left -= 2)
8. (riservato alla compattazione, Task 8)
9. compattazione (Task 8)        10. conversione (Task 8)
11. salva il piano, senza gli oggetti singoli eliminati al passo 6
```

La conferma si chiede contenitore per contenitore, mai su tutti insieme: il contenitore che il backup ha appena pubblicato non è ancora caricato, e un controllo globale fermerebbe ogni eliminazione a ogni backup. `references(of:in:cache:)` passa da `private` a interno perché lo usa anche `PackMaintenance.swift`.

`fits` e `total` contano i byte su disco (`poolSize`); la scelta dei backup da eliminare al passo 2 resta sui byte ancora usati, come oggi.

Perché è sicuro: un backup nuovo non riusa un condannato (`Repository.condemned`, che l'app imposta nel Task 9), e se lo facesse lo stesso il passo 5 lo toglie dai condannati prima di ogni eliminazione.

- [ ] **Step 1: Test che falliscono** in `PackMaintenanceTests` (helper come `PrunerTests.backup`, con `packBelow` come parametro; `refs = tmp()`):

```swift
@Test func budgetIsNeverExceededAndTheRestWaits() throws
// 6 daily backups, each with a file of its own; keepNewestOnly, maxDeletions 3, three calls:
// deletedFiles is 3, then 3, then what is left; after the last one only the newest backup and its object remain
@Test func hourlyRunsUseThePlanWithoutReadingOldManifests() throws
// loose archive with 5 orphans; collect with maxDeletions 2 (2 deleted). Then corrupt the oldest kept manifest
// and delete its cached references: a call with gcDue false and maxDeletions 2 still deletes 2 more
@Test func noPlanNoObjectDeletion() throws                 // orphans, gcDue false, no cleanup file: deletedFiles == 0
@Test func objectReusedByANewBackupIsNotDeleted() throws
// X condemned by a collection run with maxDeletions 0; a new backup saves a file with X's content WITHOUT setting
// repository.condemned; prune(gcDue: false): X is still there and the new backup restores
@Test func condemnedObjectIsStoredAgain() throws           // same, with repository.condemned = condemnedObjects(refsCache:): the backup reports newBytes > 0
@Test func deadContainerCostsTwoAndWaitsForRoom() throws   // a container only an expired backup used: maxDeletions 1 leaves it, maxDeletions 2 deletes it and deletedFiles == 2
@Test func oldContainerWaitsForTheOneHoldingTheCopy() throws
// repack the live objects of a container by hand; confirmed = { _ in false }: the old container stays, while a
// condemned single-file object is deleted all the same; with confirmed = { _ in true } the old container goes
@Test func vanishedBackupsStopObjectDeletions() throws     // a known manifest moved away: deletedFiles counts manifests only
@Test func unreadableNewManifestSkipsTheRun() throws       // a manifest newer than the plan is corrupt: no throw, no object deleted
@Test func capStoppedByTheBudgetIsPending() throws         // cap far below the data, maxDeletions 1: capPending == true; with no limit capPending == false
@Test func cleanupFileIsNotTakenForABackup() throws        // after a collection: vanished == false and gcSkipped == false at the next call
```

- [ ] **Step 2:** `swift test --filter PackMaintenanceTests` — atteso: non compila.
- [ ] **Step 3: Implementare** `CleanupOptions`, il piano, i passi 1-7 e 11, `condemnedObjects`, `packIsConfirmed`.
- [ ] **Step 4:** `swift test 2>&1 | tail -3` — atteso: tutto passato. I test esistenti di `prune` non passano `options` e non devono cambiare.
- [ ] **Step 5: Commit** `feat(core): pulizia con un tetto alle eliminazioni e un piano locale`

---

### Task 8: Compattazione e conversione

**Files:**
- Modify: `Sources/BackupCore/PackMaintenance.swift`, `Sources/BackupCore/Pruner.swift` (`PruneResult`)
- Test: `Tests/BackupCoreTests/PackMaintenanceTests.swift`

**Interfaces — Consumes:** `repack(_:)`, `packOf(_:)`, `looseObjectSizes()` (Task 2); il piano e i passi di `prune` (Task 7).

**Interfaces — Produces:**

```swift
// PruneResult gains:
public var smallFilesLeft: Int?    // single-file objects below packThreshold still there; nil when not counted
/// When the conversion ends at the pace kept since `startDate`; nil when nothing has left yet.
public func conversionEnd(startCount: Int, startDate: Date, left: Int, now: Date) -> Date?
```

**Passo 9, compattazione.** Vivi di un contenitore: le voci che sono la copia che conta e non sono condannate. Si riscrive (con `repack` dei suoi vivi) un contenitore che:

- ha meno della metà dei byte ancora vivi, oppure
- ha byte morti e l'archivio su disco supera il tetto allo spazio (prima quelli con più byte morti), oppure
- è piccolo (file sotto `packTarget / 4`) quando i piccoli sono almeno 8: allora tutti i piccoli insieme.

Per giro si scelgono contenitori finché i byte vivi scelti arrivano a `packTarget`. Se `repack` lancia `corruptObject`, quel contenitore si lascia dov'è e si passa al successivo. La compattazione non elimina niente: il contenitore vecchio risulta morto al giro dopo e lo toglie il passo 7, quando quello nuovo è confermato.

**Passo 10, conversione** (solo con `options.convert` e `!plan.conversionDone`):

- *Doppioni:* oggetti singoli che hanno anche una copia in un contenitore. Si eliminano finché `left > 0`, ciascuno solo se il contenitore con la sua copia (`packOf`) è confermato.
- *Contenitore successivo:* solo quando non restano doppioni e l'archivio su disco non supera il tetto allo spazio. Candidati: oggetti singoli sotto `packThreshold` (da `looseObjectSizes()`) non condannati; prima quelli usati dal manifest più recente (`references(of: ids.last)`), poi gli altri; se ne prendono finché i byte arrivano a `packTarget`, e si passano a `repack`.
- `smallFilesLeft` = oggetti singoli sotto `packThreshold`, doppioni compresi.
- `plan.conversionDone = true` quando una raccolta (passo 3) non trova più candidati né doppioni: da lì `looseObjectSizes()` non si chiama più.

- [ ] **Step 1: Test che falliscono:**

```swift
@Test func halfDeadContainerIsRewrittenThenRemoved() throws
// one container with 4 objects of 1000 random bytes, 3 of them used only by an expired backup; two unlimited calls:
// one container left, the live object reads back, the 3 dead ones are not in allObjectHashes
@Test func eightSmallContainersAreMergedSevenAreNot() throws
@Test func containerWithACorruptLiveObjectIsLeftAlone() throws   // flip a byte of a live object: no throw, same packIDs, the object still listed
@Test func interruptedCompactionHealsItself() throws             // repack the live objects by hand, as a crash after publishing: the next calls delete the old container and every backup restores
@Test func overTheCapEveryDeadByteIsReclaimed() throws           // a container 80% live is rewritten when poolSize exceeds the cap, and left alone when it fits
@Test func conversionMovesSmallFilesWithinTheBudget() throws
// archive written with packBelow 0: 30 files of 2000 random bytes and one of 5 MiB; reopened with packBelow 4 << 20.
// Calls with convert and maxDeletions 5 until smallFilesLeft == 0: every call has deletedFiles <= 5, after every call
// the backup restores identical, the 5 MiB object is still a file, and packIDs().count == 1
@Test func conversionWritesOneContainerAtATime() throws          // confirmed = { _ in false }: one container after the first call, still one after the third, no file deleted
@Test func condemnedSmallFilesAreNotConverted() throws           // an orphan small file never enters a container
@Test func conversionNeverCostsABackup() throws                  // archive at its cap: the snapshots deleted with convert on and off are the same
@Test func aFortnightOfHourlyBackupsStaysUnderFiftyAnHour() throws
// 14 days of hourly backups of 40 small files, 6 of which change every hour, on an archive started with packBelow 0;
// cleanup after each backup and after 3 failed retries every 15 minutes, maxDeletions from a DeletionLedger with limit 50:
// in no 60-minute window deletedFiles sums above 50, smallFilesLeft reaches 0, the newest backup always restores
@Test func conversionEndFollowsTheRealPace() {
    let t = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(conversionEnd(startCount: 1000, startDate: t, left: 1000, now: t.addingTimeInterval(86400)) == nil)
    #expect(conversionEnd(startCount: 1000, startDate: t, left: 750, now: t.addingTimeInterval(86400)) == t.addingTimeInterval(4 * 86400))
}
```

- [ ] **Step 2:** `swift test --filter PackMaintenanceTests` — atteso: i nuovi falliscono.
- [ ] **Step 3: Implementare** i passi 9 e 10 e `conversionEnd`.
- [ ] **Step 4:** `swift test 2>&1 | tail -3` — atteso: tutto passato.
- [ ] **Step 5: Commit** `feat(core): compattazione dei contenitori e conversione dei file piccoli`

---

### Task 9: L'app accende i contenitori

**Files:**
- Modify: `Sources/BackupMe/AppModel.swift` (`perform`, righe 489-590; `finish`, riga 633), `Sources/BackupMe/SettingsView.swift` (scheda Destinazione, `Info` e `load`, righe 349-357)

**Interfaces — Consumes:** `Repository.init(packBelow:)`, `condemned`, `condemnedObjects(refsCache:)`, `CleanupOptions`, `DeletionLedger`, `PruneResult.deletedFiles/capPending/smallFilesLeft`, `conversionEnd`.

In `perform`:

- L'archivio si apre con `packBelow: Repository.packThreshold`. Subito dopo `claim`: `repo.condemned = condemnedObjects(refsCache: AppPaths.refsCache(archive, destination: repo.root.path))`.
- Tetto: `limit = UserDefaults.standard.object(forKey: "deletionsPerHour") as? Int ?? 50`. Il `DeletionLedger` sta in `UserDefaults` sotto `deletionLedger` (JSON). `options.maxDeletions = ledger.allowance(limit: limit, now: Date())`.
- **Client indietro:** prima di `engine.run` si guardano il manifest più recente e il contenitore più recente che ci sono già. Se il client dà per non caricato il manifest (le stesse chiavi di `uploadProblem`: `isUbiquitousItem`, `ubiquitousItemIsUploaded`) o il contenitore non è confermato (`packIsConfirmed`), `maxDeletions = 0`. Quello che scrive il backup in corso non conta. Dove il client non dice niente, vale il solo conteggio.
- Una riga debug per backup: `Contenitori: \(n), ultimo confermato: \(sì/no), il client dichiara lo stato di caricamento: \(sì/no)`.
- `options.convert = true`. Dopo `prune`: `ledger.record(result.deletedFiles, at: Date())` e salvataggio.
- La riga info del Registro (oggi «Pulizia: N backup e M file eliminati dall'archivio») diventa, quando `deletedFiles > 0` o `smallFilesLeft` è cambiato: `Pulizia: \(deletedFiles) file eliminati dalla destinazione` e, se `smallFilesLeft` non è nil e non è 0, `, \(smallFilesLeft) file piccoli da convertire`.
- In `UserDefaults`: `smallFilesLeft` (l'ultimo valore), e alla prima volta che non è 0 `conversionStartCount` e `conversionStartDate`.
- `perform` restituisce `overCap` solo se `result.overCap && !result.capPending`: «Il tetto è troppo basso» non parte per un archivio che sta rientrando.

In `SettingsView`, scheda Destinazione, due righe sotto lo spazio occupato:

- con `smallFilesLeft > 0`: `File piccoli da convertire: \(n.formatted())` e, se `conversionEnd` non è nil, ` · fine stimata \(data.formatted(.relative(presentation: .named)))`;
- con lo spazio occupato sopra il tetto: `L'archivio sta rientrando sotto il tetto`.

- [ ] **Step 1: Implementare** le modifiche sopra.
- [ ] **Step 2:** `swift build 2>&1 | tail -3` — atteso: `Build complete!`. `swift test 2>&1 | tail -3` — atteso: tutto passato.
- [ ] **Step 3: Prova a mano** sull'archivio di prova (`~/Library/CloudStorage/Dropbox/TEST`): `scripts/build-app.sh --install`, aggiungere una cartella con qualche centinaio di file piccoli, **Esegui backup ora** due volte cambiando dei file in mezzo. Atteso: compare `packs/` con un `.pack` e un `.idx`, `repo.json` dice `"format":2`, **Sfoglia backup…** ripristina un file del primo e uno del secondo backup, **Impostazioni › Avanzate › Prova ora** riesce, il Registro ha la riga «Pulizia: …» quando qualcosa viene eliminato.
- [ ] **Step 4: Commit** `feat(app): contenitori, tetto orario alle eliminazioni e conversione graduale`

---

### Task 10: Documenti e archivio di prova del formato 2

**Files:**
- Modify: `docs/formato-archivio.md`, `README.md`, `CHANGELOG.md`
- Create: `Tests/BackupCoreTests/Fixtures/archive-2.0/`
- Modify: `Tests/BackupCoreTests/FormatFixtureTests.swift` (`versions`, `archive(_:)`)

- `docs/formato-archivio.md` diventa «formato 2»: `packs/` nella struttura; una sezione **Contenitori** con il formato del Task 1 byte per byte, la regola dell'id e «vince l'id più alto»; in **Oggetti** la frase che un oggetto può stare in una delle due forme e che dove va è una regola di chi scrive; in **Compatibilità** cosa fanno una versione vecchia e il kit 9 davanti al formato 2.
- `README.md`: una voce nella sezione dei comportamenti sul tetto di 50 file all'ora e sulla conversione, con il comando `defaults write com.vale76p.BackupMe deletionsPerHour -int 30` per abbassarlo; la nota che una versione precedente non scrive né ripristina per intero un archivio di formato 2.
- `CHANGELOG.md`: una sezione per la versione nuova (il numero lo decide Valentino al rilascio) con contenitori, tetto, conversione, kit 10 e la correzione del Task 0.
- `archive-2.0`: copia di `archive-1.0-rc1` su cui il codice di questo ramo ha fatto un backup di `Fixtures/source/source-2.tar` con `packBelow: Repository.packThreshold`, così è misto. Si genera una volta con un test temporaneo che scrive in `Fixtures/` e poi si toglie; i file generati si committano.

- [ ] **Step 1:** Aggiungere `"2.0"` a `versions` in `FormatFixtureTests` e far restituire ad `archive("2.0")` il nome di `1.0-rc1`. `swift test --filter FormatFixtureTests` — atteso: fallisce, l'archivio non c'è.
- [ ] **Step 2:** Generare e committare `archive-2.0`; aggiungere `packBytesMatchTheFormatDocument`, che rilegge il `.pack` e l'`.idx` dell'archivio di prova con `Pack.scan` e `Pack.decodeIndex` e controlla che coincidano e che ogni oggetto abbia lo SHA-256 del suo nome.
- [ ] **Step 3:** Scrivere i tre documenti.
- [ ] **Step 4:** `swift test 2>&1 | tail -3` — atteso: tutto passato, con le prove parametriche di `FormatFixtureTests` anche su `2.0`.
- [ ] **Step 5: Commit** `docs: formato 2 dell'archivio, README e CHANGELOG; archivio di prova misto`

---

## Verifica sul Mac aziendale (dopo l'installazione)

Non si può provare qui: sono i due punti che il disegno segna come non verificati.

- [ ] Dopo un backup, il Registro a livello debug riporta lo stato di caricamento dei contenitori. Se OneDrive aziendale non lo dichiara, vale la regola di ripiego (un'ora): annotarlo nella issue [vale76p/BackupMe#24](https://github.com/vale76p/BackupMe/issues/24).
- [ ] Per una settimana: nessuna email di OneDrive sulle eliminazioni. Se arriva, la riga «Pulizia: …» del Registro a quell'ora dice quanti file erano; abbassare `deletionsPerHour` e riprovare.
- [ ] **Impostazioni › Destinazione** mostra i file piccoli da convertire in calo e una stima credibile.
