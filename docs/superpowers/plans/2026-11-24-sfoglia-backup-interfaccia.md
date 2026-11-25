# BackupMe — Sfoglia backup, la finestra nuova: piano di implementazione

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** La finestra «Sfoglia backup…» ha una linea del tempo vera al posto dei chip, dice in grande in quale momento si è, un ispettore più largo con l'anteprima e una sola barra per le azioni, senza che cambi una regola di ripristino.

**Architecture:** Le regole che non dipendono dall'interfaccia (in che sezione va ogni backup, i testi di data e ora, cosa «Ripristina» ripristina e da quale backup) escono dalla finestra e vanno in un target di libreria senza SwiftUI, `RestoreRules`, provato da quarantadue test. La finestra si divide in cinque file: `RestoreView` (finestra, stato, azioni, ricerca), `RestoreTimeline`, `RestoreBrowser` (titolo, filtri, lista), `RestoreInspector`, `RestoreActionBar`. `RestoreModel` cambia di una funzione sola, `BackupCore` non cambia affatto.

**Tech Stack:** Swift 6, SwiftUI, Foundation, Quick Look Thumbnailing, Swift Testing. Nessuna dipendenza.

**Spec:** `docs/superpowers/specs/2026-11-24-sfoglia-backup-interfaccia-design.md`. I mockup: `docs/superpowers/mockups/2026-11-24-sfoglia-backup-direzioni.html` (si apre nel browser).

## Global Constraints

- macOS 14 o successivo. Il vetro solo dietro `#available(macOS 26, *)`, con gli aiuti già in `Sources/BackupMe/Glass.swift` (`glassPanel`, `glassButton`, `GlassGroup`).
- La barra laterale è una `List`: una vista a scorrimento disegnata a mano faceva sbagliare il bersaglio ai clic (0.9.0).
- Il modello tiene in memoria due indici al più; ogni lettura dall'archivio sta fuori dal thread principale (`RestoreModel.withRepository`).
- L'anteprima dell'ispettore legge dall'archivio solo file fino a 20 milioni di byte, in un task che si annulla quando cambia la selezione.
- Le regole di ripristino sono quelle di oggi: mai sovrascrivere; «Sostituisci» solo dal dialogo di una cartella salvata per intera, dopo il controllo, e solo dove è permesso; un ripristino alla volta per tutta l'app (`AppModel.restoring`).
- Messaggi all'utente in italiano; commenti nel codice in inglese, una riga, solo il perché.
- Per gli avvisi di un backup comanda la cronologia dell'app, anche quando il suo indice è in memoria: «Cancella avvisi» li toglie anche dalla linea del tempo (decisione dell'utente; come i chip di oggi).
- Una versione scelta conta come versione a sé solo se viene da un backup diverso da quello guardato (o da quello del risultato): solo allora la barra dice «versione del …»; altrimenti «dal backup di …», come sempre; davanti a una data l'articolo è «del» («dal backup del 9 novembre alle 20:00»), come in «versione del 30 ott» (scelta di Valentino durante l'esecuzione).
- Nessun ciclo tra proprietà calcolate di una vista: `selection` legge solo modello e stato, `plan` legge `selection`, `bar` legge `plan`. Un ciclo è un arresto anomalo al primo disegno, invisibile a compilazione e test; lo cerca `scripts/check-view-cycles.py` (Task 9).
- Un risultato della ricerca si ripristina anche prima che un backup sia guardato (mentre il suo indice carica), come nella finestra di oggi.
- Le viste (Task 4–8) non hanno test automatici: la spec li affida alla compilazione e alla lista di prova a schermo `docs/prova-sfoglia-backup.md`.
- I 323 test esistenti non cambiano e restano verdi. Dopo i Task 1–3 la suite è «363 test in 34 suite», dopo il Task 5 «365 test in 35 suite».
- L'app si compila ancora con `swift build --product BackupMe` e con `scripts/build-app.sh`.
- Il branch è `feat/sfoglia-backup-interfaccia`. Ogni task finisce con un commit; nessun push.
- `docs/prova-reale-rc1.md` e `AGENTS.md` non sono tracciati e non fanno parte di questo piano: non aggiungerli.

## Review Focus

1. **Le regole di `RestorePlanner.resolve` sono quelle della vecchia `targets` di `RestoreView`** (Task 3): una riga delle due tabelle della spec («Barra») per test. Chi rivede confronta test e vecchio codice.
2. **Ogni task compila da solo** (dai Task 4 all'8 la finestra vecchia vive accanto ai file nuovi): `swift build --product BackupMe` alla fine di ognuno.
3. **La linea del tempo è una `List`** e i clic cadono dove si vede (Task 4, da provare a schermo).
4. **L'anteprima non legge mai un file sopra i 20 MB e non blocca mai** (Task 6): il limite è su `entry.size`, la lettura sta in un task separato, e una carta in ritardo non sostituisce una selezione più recente.
5. **«Sostituisci» resta dov'era**: passa solo da `askWholeFolder`, con `check` e `checking` come prima (Task 8).
6. **Il vetro della capsula**: se dà glitch, torna la barra in fondo di prima (Task 7 e Task 8; ripiego deciso nella spec).
7. **`snapshotOnFATFilesystems`** (`RepositoryTests`) monta un'immagine disco con `hdiutil` e ogni tanto resta appeso o fallisce per conto suo: se capita, rilanciarlo da solo (`swift test --filter snapshotOnFATFilesystems`) prima di sospettare il codice.

8. **La finestra si apre.** Nessuno ha ancora aperto la finestra nuova: compilazione e test non vedono un arresto anomalo al primo disegno (alla revisione del Task 8 ne è uscito uno). La prima riga di `docs/prova-sfoglia-backup.md` è aprirla, e `scripts/check-view-cycles.py` guarda la classe di arresti anomali che si vede dal codice.

## File

| File | Responsabilità |
|---|---|
| `Package.swift` | Il target `RestoreRules`; l'app e i test ne dipendono |
| `Sources/RestoreRules/BackupTimeline.swift` (nuovo) | `TimelineItem`, `TimelineSection`, `BackupTimeline`: sezioni, titoli, barre, suggerimento |
| `Sources/RestoreRules/WhenText.swift` (nuovo) | `WhenText`: «Ieri alle 15:00», «dal backup di/del …», la terza riga del titolo, «versione del …» |
| `Sources/RestoreRules/RestorePlanner.swift` (nuovo) | `Entry.restoreID`, `SelectionSummary`, `RestorePlanner`: cosa si ripristina e cosa dice la barra |
| `Sources/RestoreRules/ChangeFilter.swift` (nuovo) | `ChangeFilter`, `RowStatus` e la regola: quali righe passano un filtro |
| `Sources/BackupMe/RestoreTimeline.swift` (nuovo) | La carta dello stato e la linea del tempo |
| `Sources/BackupMe/RestoreBrowser.swift` (nuovo) | `RestoreActions`, il titolo, i tag, la tabella, i risultati; `StatusBadge`, `FileIcon` |
| `Sources/BackupMe/RestoreInspector.swift` (nuovo) | L'ispettore: dettagli, carta d'anteprima, versioni |
| `Sources/BackupMe/RestoreActionBar.swift` (nuovo) | La capsula delle azioni e il suo menu |
| `Sources/BackupMe/RestoreView.swift` | Riscritto: finestra, stato, azioni, ricerca, avvisi; la barra |
| `Sources/BackupMe/RestoreModel.swift` | `matches`: una riga contro un filtro, con `ChangeFilter` e `RowStatus` presi da `RestoreRules` (Task 5); `previewCopy`: la copia temporanea silenziosa per la carta (Task 6) |
| `Sources/BackupMe/BackupMeApp.swift` | Finestra 1100×700; colore e simbolo di stato condivisi col pannello |
| `Sources/BackupMe/Glass.swift` | Il commento: il vetro vale anche per la barra di Sfoglia |
| `Tests/BackupCoreTests/RestoreRulesTestSupport.swift` (nuovo) | `Rules`: un calendario, un fuso e una lingua fissi per i test |
| `Tests/BackupCoreTests/BackupTimelineTests.swift`, `WhenTextTests.swift`, `RestorePlannerTests.swift`, `RowFilterTests.swift` (nuovi) | I quarantadue test delle regole |
| `docs/prova-sfoglia-backup.md` (nuovo), `CHANGELOG.md` | La lista di prova a schermo e la voce del changelog |
| `scripts/check-view-cycles.py` (nuovo), `README.md` | La sentinella dei cicli tra proprietà calcolate nelle viste, e come lanciarla |
| `scripts/check-view-cycles-test.py` (nuovo) | I casi che provano la sentinella: i cicli che deve trovare e il codice che deve lasciare in pace |

---

### Task 0: Base pulita e documenti

**Files:** nessuno di codice. Mette sotto git spec, mockup e questo piano.

- [ ] **Step 1:** Essere sul branch, con l'albero pulito a parte i file di questo lavoro.

```bash
git switch feat/sfoglia-backup-interfaccia
git status -sb
```

Atteso: `## feat/sfoglia-backup-interfaccia` e, tra i non tracciati, `docs/superpowers/` (più `AGENTS.md` e `docs/prova-reale-rc1.md`, che restano fuori).

- [ ] **Step 2:** La suite di partenza.

Run: `swift test 2>&1 | tail -3`
Expected: `Test run with 323 tests in 30 suites passed after … seconds.`

- [ ] **Step 3: Commit** dei documenti (solo `docs/superpowers`: dentro ci sono spec, mockup e piano).

```bash
git add docs/superpowers
git commit -m "docs: spec, mockup e piano della finestra nuova di Sfoglia backup"
```

---

### Task 1: Il target `RestoreRules` e la linea del tempo

**Files:**
- Modify: `Package.swift`
- Create: `Sources/RestoreRules/BackupTimeline.swift`
- Test: `Tests/BackupCoreTests/RestoreRulesTestSupport.swift`, `Tests/BackupCoreTests/BackupTimelineTests.swift`

**Interfaces — Produces:**

```swift
public struct TimelineItem: Identifiable, Equatable, Sendable {
    public var id: String; public var date: Date
    public var newBytes: Int64?; public var warnings: Int?
    public init(id: String, date: Date, newBytes: Int64? = nil, warnings: Int? = nil)
}
public struct TimelineSection: Identifiable, Equatable, Sendable {
    public var id: String; public var title: String; public var items: [TimelineItem] // newest first
    public var newBytes: Int64?   // nil when no item knows
}
public enum BackupTimeline {
    public static func info(from history: [BackupReport]) -> [String: (newBytes: Int64, warnings: Int)]
    public static func items(snapshots: [(id: String, date: Date)], history: [BackupReport],
                             indexWarnings: (String) -> Int?) -> [TimelineItem]
    public static func sections(_ items: [TimelineItem], now: Date = Date(), calendar: Calendar = .current,
                                locale: Locale = Locale(identifier: "it_IT")) -> [TimelineSection]
    public static func dayTitle(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String
    public static func monthTitle(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String
    public static func barWidth(_ item: TimelineItem, in items: [TimelineItem]) -> Double?
    public static func hourLabel(_ date: Date, calendar: Calendar = .current, locale: Locale = Locale(identifier: "it_IT")) -> String
    public static func bytesText(_ bytes: Int64, locale: Locale = Locale(identifier: "it_IT")) -> String
    public static func warningsText(_ warnings: Int) -> String
    public static func barLabel(_ item: TimelineItem, locale: Locale = Locale(identifier: "it_IT")) -> String
    public static func detail(_ item: TimelineItem, calendar: Calendar = .current, locale: Locale = Locale(identifier: "it_IT")) -> String
}
// internal to RestoreRules: the next task's WhenText leans on them too
extension Calendar {
    func timelineWeekStart(now: Date) -> Date            // six days before today, at midnight
    func isYesterday(_ date: Date, now: Date) -> Bool
    func isAnotherYear(_ date: Date, now: Date) -> Bool
}
extension Date { func todayOrYesterday(now: Date, calendar: Calendar) -> String? }   // "Oggi", "Ieri", nil
```

- [ ] **Step 1: Dichiarare il target** in `Package.swift`. Sostituire l'intero `let package = Package( … )` con:

```swift
let package = Package(
    name: "BackupMe",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "BackupCore"),
        // The rules of the Sfoglia window that need no interface, apart so the tests can reach them
        .target(name: "RestoreRules", dependencies: ["BackupCore"]),
        .executableTarget(name: "BackupMe", dependencies: ["BackupCore", "RestoreRules"]),
    ] + (hasTests ? [.testTarget(name: "BackupCoreTests", dependencies: ["BackupCore", "RestoreRules"], resources: [.copy("Fixtures")])] : [])
)
```

- [ ] **Step 2: Scrivere i test che devono fallire.** Creare `Tests/BackupCoreTests/RestoreRulesTestSupport.swift`:

```swift
import BackupCore
import Foundation
@testable import RestoreRules

/// One calendar, one time zone, one locale: the rules read the same wherever the tests run.
enum Rules {
    static let it = Locale(identifier: "it_IT")
    static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Rome")!
        return c
    }()

    static func d(_ y: Int, _ m: Int, _ day: Int, _ h: Int = 20, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: day, hour: h, minute: minute))!
    }

    /// A backup with its new bytes in MB.
    static func item(_ date: Date, _ mb: Int64? = nil, warnings: Int? = nil) -> TimelineItem {
        TimelineItem(id: Snapshot.id(for: date), date: date, newBytes: mb.map { $0 * 1_000_000 }, warnings: warnings)
    }

    static let source = "/Users/x/Progetti"

    /// A file of a saved folder; `path` is relative to it.
    static func entry(_ path: String, kind: EntryKind = .file, source: String = Rules.source, size: Int64 = 10) -> Entry {
        Entry(source: source, path: path, kind: kind, hash: kind == .file ? String(repeating: "a", count: 64) : nil, size: size,
              mtime: d(2026, 11, 23, 14, 2), mode: 0o644, linkTarget: nil)
    }
}
```

E `Tests/BackupCoreTests/BackupTimelineTests.swift`:

```swift
import Foundation
import Testing
@testable import BackupCore
@testable import RestoreRules

@Suite struct BackupTimelineTests {
    /// A Tuesday afternoon.
    var now: Date { Rules.d(2026, 11, 24, 20, 15) }

    func sections(_ items: [TimelineItem], now: Date) -> [TimelineSection] {
        BackupTimeline.sections(items, now: now, calendar: Rules.cal, locale: Rules.it)
    }
    func titles(_ items: [TimelineItem], now: Date) -> [String] { sections(items, now: now).map(\.title) }

    @Test func oneSectionPerDayOfTheLastWeekThenPerMonth() {
        let s = sections([
            Rules.item(Rules.d(2026, 11, 17)), Rules.item(Rules.d(2026, 10, 30)), Rules.item(Rules.d(2026, 11, 24, 15)),
            Rules.item(Rules.d(2026, 11, 22)), Rules.item(Rules.d(2025, 12, 10)), Rules.item(Rules.d(2026, 11, 23, 23)),
            Rules.item(Rules.d(2026, 11, 24, 20)), Rules.item(Rules.d(2026, 11, 18)), Rules.item(Rules.d(2026, 11, 23, 15)),
        ], now: now)
        #expect(s.map(\.title) == ["Oggi · 24 nov", "Ieri · 23 nov", "Domenica 22 nov", "Mercoledì 18 nov",
                                   "Novembre", "Ottobre", "Dicembre 2025"])
        #expect(s.map { $0.items.count } == [2, 2, 1, 1, 1, 1, 1])
        // whatever the order they come in, the newest is first
        #expect(s[0].items.map(\.date) == [Rules.d(2026, 11, 24, 20), Rules.d(2026, 11, 24, 15)])
    }

    @Test func theWeekStartsSixDaysAgoAtMidnight() {
        #expect(titles([Rules.item(Rules.d(2026, 11, 18, 0, 0)), Rules.item(Rules.d(2026, 11, 17, 23, 59))], now: now)
                == ["Mercoledì 18 nov", "Novembre"])
    }

    @Test func midnightPartsOneDayFromTheNext() {
        #expect(titles([Rules.item(Rules.d(2026, 11, 24, 0, 0)), Rules.item(Rules.d(2026, 11, 23, 23, 59))], now: Rules.d(2026, 11, 24, 0, 30))
                == ["Oggi · 24 nov", "Ieri · 23 nov"])
    }

    @Test func theDaysTheClockChanges() {
        // 29 March 2026 has 23 hours in Rome and 25 October has 25: the week still starts six days back at midnight
        #expect(titles([Rules.item(Rules.d(2026, 3, 23, 0, 30)), Rules.item(Rules.d(2026, 3, 22, 23, 30)),
                        Rules.item(Rules.d(2026, 3, 29, 0, 30)), Rules.item(Rules.d(2026, 3, 29, 3, 30))], now: Rules.d(2026, 3, 29, 12))
                == ["Oggi · 29 mar", "Lunedì 23 mar", "Marzo"])
        #expect(titles([Rules.item(Rules.d(2026, 10, 19, 3, 30)), Rules.item(Rules.d(2026, 10, 18, 23, 30))], now: Rules.d(2026, 10, 25, 12))
                == ["Lunedì 19 ott", "Ottobre"])
    }

    @Test func monthAndYearEnds() {
        // December the 1st: the 26th is still in the week, the 24th isn't
        #expect(titles([Rules.item(Rules.d(2026, 12, 1, 8)), Rules.item(Rules.d(2026, 11, 30)), Rules.item(Rules.d(2026, 11, 26)),
                        Rules.item(Rules.d(2026, 11, 24))], now: Rules.d(2026, 12, 1, 9))
                == ["Oggi · 1 dic", "Ieri · 30 nov", "Giovedì 26 nov", "Novembre"])
        // a new year: December keeps its year
        #expect(titles([Rules.item(Rules.d(2026, 12, 31)), Rules.item(Rules.d(2026, 12, 20))], now: Rules.d(2027, 1, 1, 9))
                == ["Ieri · 31 dic", "Dicembre 2026"])
    }

    @Test func twoBackupsInTheSameHourStayBoth() {
        let a = Rules.item(Rules.d(2026, 11, 24, 15, 0)), b = Rules.item(Rules.d(2026, 11, 24, 15, 40))
        let s = sections([a, b], now: now)
        #expect(s.count == 1)
        #expect(s[0].items.map(\.date) == [b.date, a.date])
        #expect(s[0].items.map { BackupTimeline.hourLabel($0.date, calendar: Rules.cal, locale: Rules.it) } == ["15:40", "15:00"])
    }

    @Test func aSectionSumsWhatItKnows() {
        let a = Rules.item(Rules.d(2026, 11, 24, 20), 12), b = Rules.item(Rules.d(2026, 11, 24, 15), 38), c = Rules.item(Rules.d(2026, 11, 24, 8))
        #expect(sections([a, b, c], now: now)[0].newBytes == 50_000_000)
        #expect(sections([c], now: now)[0].newBytes == nil)
    }

    @Test func anEmptyArchiveHasNoSections() {
        #expect(sections([], now: now).isEmpty)
    }

    @Test func onlyTheRunThatWroteTheIndexCounts() {
        let made = Rules.d(2026, 11, 23, 15), id = Snapshot.id(for: made)
        let history = [
            BackupReport(snapshotID: id, date: made, duration: 3, fileCount: 10, newBytes: 210_000_000, warnings: [], error: nil),
            // two hours later nothing changed: the run names the same index, and it isn't its own
            BackupReport(snapshotID: id, date: made.addingTimeInterval(7200), duration: 1, fileCount: 10, newBytes: 0, warnings: [], error: nil),
            BackupReport(snapshotID: nil, date: made, duration: 1, fileCount: 0, newBytes: 0, warnings: ["a"], error: nil),
        ]
        let known = BackupTimeline.info(from: history)
        #expect(known.count == 1)
        #expect(known[id]?.newBytes == 210_000_000)
        #expect(known[id]?.warnings == 0)
    }

    @Test func aFailedRunCountsItsErrorsAsWarnings() {
        let made = Rules.d(2026, 11, 22, 20), id = Snapshot.id(for: made)
        let history = [BackupReport(snapshotID: id, date: made, duration: 1, fileCount: 1, newBytes: 5_000_000,
                                    warnings: ["w1", "w2"], error: "e1\ne2\ne3")]
        let known = BackupTimeline.info(from: history)
        #expect(known[id]?.newBytes == 5_000_000)
        #expect(known[id]?.warnings == 5)
    }

    @Test func theHistoryWinsOverTheIndex() {
        // «Cancella avvisi» empties the last run's warnings in the app's history: the timeline follows it, index or not
        let a = Rules.d(2026, 11, 23, 15), b = Rules.d(2026, 11, 20, 20), c = Rules.d(2026, 11, 18, 20)
        let id = Snapshot.id(for: a)
        let index = { (id: String) -> Int? in id == Snapshot.id(for: b) ? 2 : id == Snapshot.id(for: a) ? 9 : nil }
        let report = BackupReport(snapshotID: id, date: a, duration: 1, fileCount: 1, newBytes: 1_000_000, warnings: ["w"], error: nil)
        let items = BackupTimeline.items(snapshots: [a, b, c].map { (id: Snapshot.id(for: $0), date: $0) }, history: [report], indexWarnings: index)
        #expect(items.map(\.newBytes) == [1_000_000, nil, nil])
        // what the history knows stands, even where an index in memory says otherwise
        #expect(items.map(\.warnings) == [1, 2, nil])
        // and once the warnings are cleared nothing brings them back
        let cleared = BackupReport(snapshotID: id, date: a, duration: 1, fileCount: 1, newBytes: 1_000_000, warnings: [], error: nil)
        #expect(BackupTimeline.items(snapshots: [(id: id, date: a)], history: [cleared], indexWarnings: index).first?.warnings == 0)
    }

    @Test func barsAreProportionalToTheLargest() {
        let items = [Rules.item(Rules.d(2026, 11, 24, 20), 210), Rules.item(Rules.d(2026, 11, 24, 15), 105),
                     Rules.item(Rules.d(2026, 11, 24, 8), 0), TimelineItem(id: "x", date: Rules.d(2026, 11, 24, 7))]
        #expect(BackupTimeline.barWidth(items[0], in: items) == 1)
        #expect(BackupTimeline.barWidth(items[1], in: items) == 0.5)
        #expect(BackupTimeline.barWidth(items[2], in: items) == 0)
        #expect(BackupTimeline.barWidth(items[3], in: items) == nil)
        #expect(BackupTimeline.barLabel(items[0], locale: Rules.it) == "+210 MB")
        #expect(BackupTimeline.barLabel(items[2], locale: Rules.it) == "")
        #expect(BackupTimeline.barLabel(items[3], locale: Rules.it) == "")
    }

    @Test func withNothingButZerosTheBarIsEmpty() {
        let items = [Rules.item(Rules.d(2026, 11, 24, 20), 0)]
        #expect(BackupTimeline.barWidth(items[0], in: items) == 0)
    }

    @Test func theTooltipSaysEverything() {
        let date = Rules.d(2026, 11, 23, 15)
        func detail(_ item: TimelineItem) -> String { BackupTimeline.detail(item, calendar: Rules.cal, locale: Rules.it) }
        #expect(detail(Rules.item(date, 210, warnings: 1)) == "lunedì 23 novembre 2026 alle ore 15:00 · +210 MB nuovi · 1 avviso")
        #expect(detail(Rules.item(date, warnings: 3)) == "lunedì 23 novembre 2026 alle ore 15:00 · 3 avvisi")
        #expect(detail(Rules.item(date)) == "lunedì 23 novembre 2026 alle ore 15:00")
    }
}
```

- [ ] **Step 3: Lanciarli e vederli fallire.**

Run: `swift test --filter "BackupTimelineTests|WhenTextTests|RestorePlannerTests|SelectionSummaryTests|RowFilterTests"`
Expected: la compilazione si ferma su `error: … Source files for target RestoreRules should be located under 'Sources/RestoreRules'` (il target c'è, i sorgenti no).

- [ ] **Step 4: Scrivere la regola.** Creare `Sources/RestoreRules/BackupTimeline.swift`:

```swift
import BackupCore
import Foundation

/// One backup as the timeline lists it.
public struct TimelineItem: Identifiable, Equatable, Sendable {
    public var id: String
    public var date: Date
    /// From this Mac's history, or from the index once read; nil when neither knows.
    public var newBytes: Int64?
    public var warnings: Int?

    public init(id: String, date: Date, newBytes: Int64? = nil, warnings: Int? = nil) {
        self.id = id; self.date = date; self.newBytes = newBytes; self.warnings = warnings
    }
}

/// A day of the last week, or a month.
public struct TimelineSection: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    /// Newest first.
    public var items: [TimelineItem]

    /// The new bytes of the backups whose data is known; nil when none is.
    public var newBytes: Int64? {
        let known = items.compactMap(\.newBytes)
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    init(id: String, title: String, items: [TimelineItem]) { self.id = id; self.title = title; self.items = items }
}

extension Date {
    /// The ways the rules write a date: "22 nov", "30 ott 2025", "domenica", "9 novembre", "10 dicembre 2025", "lunedì 23 novembre 2026", "novembre".
    enum RuleStyle { case day, dayMonth, dayMonthYear, weekday, dayMonthLong, dayMonthLongYear, weekdayDayMonthLongYear, month }

    /// In a calendar and a locale given once: the rules must read the same on every Mac, and in the tests.
    func rule(_ style: RuleStyle, calendar: Calendar, locale: Locale) -> String {
        let s = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        return switch style {
        case .day: formatted(s.day())
        case .dayMonth: formatted(s.day().month(.abbreviated))
        case .dayMonthYear: formatted(s.day().month(.abbreviated).year())
        case .weekday: formatted(s.weekday(.wide))
        case .dayMonthLong: formatted(s.day().month(.wide))
        case .dayMonthLongYear: formatted(s.day().month(.wide).year())
        case .weekdayDayMonthLongYear: formatted(s.weekday(.wide).day().month(.wide).year())
        case .month: formatted(s.month(.wide))
        }
    }
}

extension String {
    /// "Domenica" from "domenica": the first letter only, so a day number stays as it is.
    var firstUp: String { prefix(1).uppercased() + String(dropFirst()) }
}

extension Calendar {
    /// The first of the seven days the timeline lists one by one: six days before today, at midnight.
    func timelineWeekStart(now: Date) -> Date { date(byAdding: .day, value: -6, to: startOfDay(for: now)) ?? now }

    /// Whether `date` falls on the day before `now`.
    func isYesterday(_ date: Date, now: Date) -> Bool {
        self.date(byAdding: .day, value: -1, to: now).map { isDate(date, inSameDayAs: $0) } ?? false
    }

    /// Whether `date` falls in another year than `now`.
    func isAnotherYear(_ date: Date, now: Date) -> Bool { component(.year, from: date) != component(.year, from: now) }
}

extension Date {
    /// "Oggi" or "Ieri" when the day is one of those two; nil for every other day.
    func todayOrYesterday(now: Date, calendar: Calendar) -> String? {
        if calendar.isDate(self, inSameDayAs: now) { return "Oggi" }
        if calendar.isYesterday(self, now: now) { return "Ieri" }
        return nil
    }
}

public enum BackupTimeline {
    /// New bytes and warnings of the backups the app's history holds (its last 50 runs); a run with no changes reused an older backup, so only the run that wrote an index counts.
    /// For warnings the history is the record even once its index is in memory: «Cancella avvisi» empties it for the last backup, and the timeline follows.
    public static func info(from history: [BackupReport]) -> [String: (newBytes: Int64, warnings: Int)] {
        var known: [String: (newBytes: Int64, warnings: Int)] = [:]
        for r in history {
            guard let id = r.snapshotID, let made = Snapshot.date(fromID: id), abs(made.timeIntervalSince(r.date)) < 2 else { continue }
            // a partial backup (a folder unreadable, no room for some files) is marked too
            known[id] = (r.newBytes, Restorer.boundedCount(r.warnings) + Restorer.boundedCount(r.error?.split(separator: "\n").map(String.init) ?? []))
        }
        return known
    }

    /// Every backup with what is known about it; `indexWarnings` answers only for a backup the history says nothing about.
    public static func items(snapshots: [(id: String, date: Date)], history: [BackupReport],
                             indexWarnings: (String) -> Int?) -> [TimelineItem] {
        let known = info(from: history)
        return snapshots.map {
            TimelineItem(id: $0.id, date: $0.date, newBytes: known[$0.id]?.newBytes,
                         warnings: known[$0.id]?.warnings ?? indexWarnings($0.id))
        }
    }

    /// One section per day of the last week (today included), then one per month. Newest first.
    public static func sections(_ items: [TimelineItem], now: Date = Date(), calendar: Calendar = .current,
                                locale: Locale = Locale(identifier: "it_IT")) -> [TimelineSection] {
        let weekStart = calendar.timelineWeekStart(now: now)
        var result: [TimelineSection] = []
        for item in items.sorted(by: { $0.date > $1.date }) {
            let key: String, title: String
            if item.date >= weekStart {
                key = "d" + String(calendar.startOfDay(for: item.date).timeIntervalSinceReferenceDate)
                title = dayTitle(item.date, now: now, calendar: calendar, locale: locale)
            } else {
                key = "m\(calendar.component(.year, from: item.date))-\(calendar.component(.month, from: item.date))"
                title = monthTitle(item.date, now: now, calendar: calendar, locale: locale)
            }
            if let last = result.indices.last, result[last].id == key { result[last].items.append(item) }
            else { result.append(TimelineSection(id: key, title: title, items: [item])) }
        }
        return result
    }

    /// "Oggi · 24 nov", "Ieri · 23 nov", "Domenica 22 nov".
    public static func dayTitle(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let day = date.rule(.dayMonth, calendar: calendar, locale: locale)
        if let named = date.todayOrYesterday(now: now, calendar: calendar) { return named + " · " + day }
        return date.rule(.weekday, calendar: calendar, locale: locale).firstUp + " " + day
    }

    /// "Novembre", with the year when it isn't the current one: "Dicembre 2025".
    public static func monthTitle(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let month = date.rule(.month, calendar: calendar, locale: locale).firstUp
        return calendar.isAnotherYear(date, now: now) ? month + " " + String(calendar.component(.year, from: date)) : month
    }

    /// Width of an item's bar, 0...1, against the largest of `items`; nil when its data is unknown.
    public static func barWidth(_ item: TimelineItem, in items: [TimelineItem]) -> Double? {
        guard let bytes = item.newBytes else { return nil }
        let largest = items.compactMap(\.newBytes).max() ?? 0
        return largest > 0 ? Double(bytes) / Double(largest) : 0
    }

    /// "15:00"
    public static func hourLabel(_ date: Date, calendar: Calendar = .current,
                                 locale: Locale = Locale(identifier: "it_IT")) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar,
                                        timeZone: calendar.timeZone))
    }

    public static func bytesText(_ bytes: Int64, locale: Locale = Locale(identifier: "it_IT")) -> String {
        bytes.formatted(.byteCount(style: .file).locale(locale))
    }

    public static func warningsText(_ warnings: Int) -> String { warnings == 1 ? "1 avviso" : "\(warnings) avvisi" }

    /// "+210 MB" under a bar; "" with nothing saved or nothing known.
    public static func barLabel(_ item: TimelineItem, locale: Locale = Locale(identifier: "it_IT")) -> String {
        guard let bytes = item.newBytes, bytes > 0 else { return "" }
        return "+" + bytesText(bytes, locale: locale)
    }

    /// What the tooltip and VoiceOver read: "lunedì 23 novembre 2026 alle ore 15:00 · +210 MB nuovi · 1 avviso".
    public static func detail(_ item: TimelineItem, calendar: Calendar = .current,
                              locale: Locale = Locale(identifier: "it_IT")) -> String {
        var text = item.date.formatted(Date.FormatStyle(date: .complete, time: .shortened, locale: locale, calendar: calendar,
                                                        timeZone: calendar.timeZone))
        if let bytes = item.newBytes, bytes > 0 { text += " · +" + bytesText(bytes, locale: locale) + " nuovi" }
        if let warnings = item.warnings, warnings > 0 { text += " · " + warningsText(warnings) }
        return text
    }
}
```

- [ ] **Step 5: Lanciare i test e vederli passare.**

Run: `swift test --filter "BackupTimelineTests|WhenTextTests|RestorePlannerTests|SelectionSummaryTests|RowFilterTests"`
Expected: `Test run with 14 tests in 1 suite passed`

- [ ] **Step 6: L'app compila ancora.**

Run: `swift build --product BackupMe`
Expected: `Build complete!`

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/RestoreRules Tests/BackupCoreTests/RestoreRulesTestSupport.swift Tests/BackupCoreTests/BackupTimelineTests.swift
git commit -m "feat(app): la linea del tempo di Sfoglia: sezioni, barre e dati di ogni backup, col target RestoreRules"
```

---

### Task 2: `WhenText`

**Files:**
- Create: `Sources/RestoreRules/WhenText.swift`
- Test: `Tests/BackupCoreTests/WhenTextTests.swift`

**Interfaces — Consumes (Task 1):** `BackupTimeline.hourLabel`, `.bytesText`, `.warningsText`, `TimelineItem`, `Date.rule(_:calendar:locale:)`, `String.firstUp`, e gli aiuti interni `Calendar.timelineWeekStart(now:)`, `Calendar.isYesterday(_:now:)`, `Calendar.isAnotherYear(_:now:)`, `Date.todayOrYesterday(now:calendar:)`, che `WhenText` usa invece di rifare gli stessi calcoli.

**Interfaces — Produces:**

```swift
public enum WhenText {
    public static func title(_ date: Date, now: Date = Date(), calendar: Calendar = .current,
                             locale: Locale = Locale(identifier: "it_IT")) -> String   // "Ieri alle 15:00"
    public static func from(_ date: Date, now: Date = Date(), calendar: Calendar = .current,
                            locale: Locale = Locale(identifier: "it_IT")) -> String                              // "dal backup di ieri alle 15:00"
    public static func subtitle(_ item: TimelineItem, calendar: Calendar = .current,
                                locale: Locale = Locale(identifier: "it_IT")) -> String                          // "lunedì 23 novembre 2026 · +210 MB salvati · 1 avviso"
    public static func version(_ date: Date, now: Date = Date(), calendar: Calendar = .current,
                               locale: Locale = Locale(identifier: "it_IT")) -> String                          // "versione del 30 ott, 20:00"
}
```

- [ ] **Step 1: Scrivere i test che devono fallire.** Creare `Tests/BackupCoreTests/WhenTextTests.swift`:

```swift
import Foundation
import Testing
@testable import BackupCore
@testable import RestoreRules

@Suite struct WhenTextTests {
    /// A Tuesday afternoon.
    var now: Date { Rules.d(2026, 11, 24, 20, 15) }

    func title(_ date: Date) -> String { WhenText.title(date, now: now, calendar: Rules.cal, locale: Rules.it) }
    func from(_ date: Date) -> String { WhenText.from(date, now: now, calendar: Rules.cal, locale: Rules.it) }
    func subtitle(_ item: TimelineItem) -> String { WhenText.subtitle(item, calendar: Rules.cal, locale: Rules.it) }
    func version(_ date: Date) -> String { WhenText.version(date, now: now, calendar: Rules.cal, locale: Rules.it) }

    @Test func todayYesterdayTheWeekThenTheMonths() {
        #expect(title(Rules.d(2026, 11, 24, 14)) == "Oggi alle 14:00")
        #expect(title(Rules.d(2026, 11, 23, 23, 15)) == "Ieri alle 23:15")
        #expect(title(Rules.d(2026, 11, 22)) == "Domenica 22 alle 20:00")
        #expect(title(Rules.d(2026, 11, 18)) == "Mercoledì 18 alle 20:00")
        #expect(title(Rules.d(2026, 11, 9)) == "9 novembre alle 20:00")
        #expect(title(Rules.d(2025, 12, 10)) == "10 dicembre 2025 alle 20:00")
    }

    @Test func theBarSaysTheSameInLowerCase() {
        #expect(from(Rules.d(2026, 11, 24, 14)) == "dal backup di oggi alle 14:00")
        #expect(from(Rules.d(2026, 11, 23, 15)) == "dal backup di ieri alle 15:00")
        #expect(from(Rules.d(2026, 11, 22)) == "dal backup di domenica 22 alle 20:00")
        #expect(from(Rules.d(2026, 11, 9)) == "dal backup del 9 novembre alle 20:00")
        #expect(from(Rules.d(2025, 12, 10)) == "dal backup del 10 dicembre 2025 alle 20:00")
    }

    @Test func theThirdLineTellsTheDataOfTheBackup() {
        let date = Rules.d(2026, 11, 23, 15)
        #expect(subtitle(Rules.item(date, 210, warnings: 1)) == "lunedì 23 novembre 2026 · +210 MB salvati · 1 avviso")
        #expect(subtitle(Rules.item(date, 210)) == "lunedì 23 novembre 2026 · +210 MB salvati")
        #expect(subtitle(Rules.item(date)) == "lunedì 23 novembre 2026")
        #expect(subtitle(Rules.item(date, 0)) == "lunedì 23 novembre 2026")
    }

    @Test func aVersionIsNamedByItsDay() {
        #expect(version(Rules.d(2026, 11, 24, 19)) == "versione di oggi, 19:00")
        #expect(version(Rules.d(2026, 11, 23, 19)) == "versione di ieri, 19:00")
        #expect(version(Rules.d(2026, 10, 30)) == "versione del 30 ott, 20:00")
        #expect(version(Rules.d(2025, 12, 10)) == "versione del 10 dic 2025, 20:00")
    }
}
```

- [ ] **Step 2: Lanciarli e vederli fallire.**

Run: `swift test --filter "BackupTimelineTests|WhenTextTests|RestorePlannerTests|SelectionSummaryTests|RowFilterTests"`
Expected: `error: cannot find 'WhenText' in scope`

- [ ] **Step 3: Scrivere la regola.** Creare `Sources/RestoreRules/WhenText.swift`:

```swift
import Foundation

/// The words that say when: the title above the list, and the line of the bar.
public enum WhenText {
    /// "Ieri alle 15:00", "Domenica 22 alle 20:00", "9 novembre alle 20:00".
    public static func title(_ date: Date, now: Date = Date(), calendar: Calendar = .current,
                             locale: Locale = Locale(identifier: "it_IT")) -> String {
        let time = BackupTimeline.hourLabel(date, calendar: calendar, locale: locale)
        if let named = date.todayOrYesterday(now: now, calendar: calendar) { return named + " alle " + time }
        // the days of the last week keep the weekday of the timeline; older ones read better with the month in full
        let day = date >= calendar.timelineWeekStart(now: now)
            ? date.rule(.weekday, calendar: calendar, locale: locale).firstUp + " " + date.rule(.day, calendar: calendar, locale: locale)
            : date.rule(calendar.isAnotherYear(date, now: now) ? .dayMonthLongYear : .dayMonthLong, calendar: calendar, locale: locale)
        return day + " alle " + time
    }

    /// "dal backup di ieri alle 15:00", "dal backup del 9 novembre alle 20:00": the same words, lower case, for the line of the bar.
    public static func from(_ date: Date, now: Date = Date(), calendar: Calendar = .current,
                            locale: Locale = Locale(identifier: "it_IT")) -> String {
        let text = title(date, now: now, calendar: calendar, locale: locale)
        // a day written as a date takes the article, as «versione del 30 ott» does; a day with its name does not
        let article = text.first?.isNumber == true ? "del" : "di"
        return "dal backup " + article + " " + text.prefix(1).lowercased() + String(text.dropFirst())
    }

    /// "lunedì 23 novembre 2026 · +210 MB salvati · 1 avviso": the third line of the title.
    public static func subtitle(_ item: TimelineItem, calendar: Calendar = .current,
                                locale: Locale = Locale(identifier: "it_IT")) -> String {
        var text = item.date.rule(.weekdayDayMonthLongYear, calendar: calendar, locale: locale)
        if let bytes = item.newBytes, bytes > 0 { text += " · +" + BackupTimeline.bytesText(bytes, locale: locale) + " salvati" }
        if let warnings = item.warnings, warnings > 0 { text += " · " + BackupTimeline.warningsText(warnings) }
        return text
    }

    /// "versione del 30 ott, 20:00", "versione di oggi, 20:00".
    public static func version(_ date: Date, now: Date = Date(), calendar: Calendar = .current,
                               locale: Locale = Locale(identifier: "it_IT")) -> String {
        let time = BackupTimeline.hourLabel(date, calendar: calendar, locale: locale)
        if let named = date.todayOrYesterday(now: now, calendar: calendar) { return "versione di " + named.lowercased() + ", " + time }
        return "versione del " + date.rule(calendar.isAnotherYear(date, now: now) ? .dayMonthYear : .dayMonth, calendar: calendar, locale: locale) + ", " + time
    }
}
```

- [ ] **Step 4: Lanciare i test e vederli passare.**

Run: `swift test --filter "BackupTimelineTests|WhenTextTests|RestorePlannerTests|SelectionSummaryTests|RowFilterTests"`
Expected: `Test run with 18 tests in 2 suites passed` (i 14 del Task 1 e questi 4).

- [ ] **Step 5: Commit**

```bash
git add Sources/RestoreRules/WhenText.swift Tests/BackupCoreTests/WhenTextTests.swift
git commit -m "feat(app): i testi di quando in Sfoglia: Oggi alle, dal backup di, versione del"
```

---

### Task 3: `RestorePlanner` e `SelectionSummary`

**Files:**
- Create: `Sources/RestoreRules/RestorePlanner.swift`
- Test: `Tests/BackupCoreTests/RestorePlannerTests.swift`

**Interfaces — Consumes:** `WhenText.from`, `WhenText.version`, `BackupTimeline.bytesText` (Task 1 e 2).

**Interfaces — Produces:**

```swift
public extension Entry {
    var restoreID: String { get }     // source + "\u{0}" + path
    var hasContent: Bool { get }      // false per un file o collegamento «Nuovo» (oggi sul disco, non nel backup)
}
public enum SelectionSummary {
    public static func count(_ n: Int) -> String                 // "3 elementi selezionati"
    public static func text(_ entries: [Entry], locale: Locale = Locale(identifier: "it_IT")) -> String   // "2 cartelle e 1 file · 2,4 MB"
}
public enum RestorePlanner {
    public struct Backup: Equatable, Sendable { public var id: String; public var date: Date; public init(id:date:) }
    public struct Hit: Equatable, Sendable { public var backup: Backup; public var entry: Entry; public init(backup:entry:) }
    public struct Selection: Equatable, Sendable {
        public var backup: Backup?; public var searching: Bool; public var hit: Hit?
        public var source: String?; public var path: String
        public var visible: [Entry]; public var selectedIDs: Set<String>
        public var version: Hit?; public var sources: [String]
        public init(backup: Backup? = nil, searching: Bool = false, hit: Hit? = nil, source: String? = nil, path: String = "",
                    visible: [Entry] = [], selectedIDs: Set<String> = [], version: Hit? = nil, sources: [String] = [])
    }
    public struct Item: Equatable, Sendable {
        public var source: String; public var path: String; public var entry: Entry?
        public init(source: String, path: String, entry: Entry? = nil); public init(_ entry: Entry)
    }
    public struct Plan: Equatable, Sendable {
        public enum Action: Equatable, Sendable { case nothing, items([Item]), version(Item), wholeFolder(String), wholeBackup }
        public var action: Action; public var from: Backup?; public var isVersion: Bool { get }   // derived from action
        public var asksFirst: Bool { get }; public var items: [Item] { get }
    }
    public static func resolve(_ s: Selection) -> Plan
    public struct Bar: Equatable, Sendable {
        public enum Icon: Hashable, Sendable { case none, file, folder, stack, drive }
        public enum Button: Hashable, Sendable { case preview, compare, reveal, restore, restoreAll }
        public var icon: Icon; public var name: String; public var detail: String; public var buttons: [Button]
    }
    public static func bar(_ plan: Plan, selection s: Selection, compare: Bool, now: Date = Date(),
                           calendar: Calendar = .current, locale: Locale = Locale(identifier: "it_IT")) -> Bar
}
```

- [ ] **Step 1: Scrivere i test che devono fallire.** Creare `Tests/BackupCoreTests/RestorePlannerTests.swift`. Un test per ogni riga delle due tabelle della spec («Barra»), più i casi ai confini:

```swift
import Testing
@testable import BackupCore
@testable import RestoreRules

@Suite struct RestorePlannerTests {
    let source = Rules.source, other = "/Users/x/Documenti"
    // the backup being browsed, and an older one
    var backup: RestorePlanner.Backup { .init(id: Snapshot.id(for: Rules.d(2026, 11, 23, 15)), date: Rules.d(2026, 11, 23, 15)) }
    var older: RestorePlanner.Backup { .init(id: Snapshot.id(for: Rules.d(2026, 10, 30, 20)), date: Rules.d(2026, 10, 30, 20)) }
    var file: Entry { Rules.entry("BackupMe/README.md", size: 15_000) }
    var folder: Entry { Rules.entry("BackupMe", kind: .directory) }
    var saved: Entry { Rules.entry("", kind: .directory) }
    var savedOther: Entry { Rules.entry("", kind: .directory, source: other) }
    /// On disk today and not in the backup: it has no hash.
    var added: Entry {
        Entry(source: source, path: "BackupMe/AGENTS.md", kind: .file, hash: nil, size: 366, mtime: Rules.d(2026, 11, 8),
              mode: 0o644, linkTarget: nil)
    }

    /// Browsing a folder: `visible` is what the list shows, `selected` the rows chosen among them.
    func browsing(source: String? = Rules.source, path: String = "BackupMe", visible: [Entry], selected: [Entry],
                  version: RestorePlanner.Hit? = nil) -> RestorePlanner.Selection {
        RestorePlanner.Selection(backup: backup, source: source, path: path, visible: visible,
                                 selectedIDs: Set(selected.map(\.restoreID)), version: version, sources: [Rules.source, other])
    }

    func bar(_ selection: RestorePlanner.Selection, compare: Bool = false) -> RestorePlanner.Bar {
        RestorePlanner.bar(RestorePlanner.resolve(selection), selection: selection, compare: compare,
                           now: Rules.d(2026, 11, 24, 20, 15), calendar: Rules.cal, locale: Rules.it)
    }

    @Test func nothingWithoutABackup() {
        #expect(RestorePlanner.resolve(RestorePlanner.Selection()).action == .nothing)
    }

    @Test func insideAFolderWithNothingSelectedTheFolderIsRestored() {
        let plan = RestorePlanner.resolve(browsing(path: "BackupMe/Sources", visible: [folder, file], selected: []))
        #expect(plan.action == .items([.init(source: source, path: "BackupMe/Sources")]))
        #expect(plan.from == backup)
        #expect(!plan.asksFirst)
    }

    @Test func theSelectedRowsAndOnlyThose() {
        let plan = RestorePlanner.resolve(browsing(visible: [folder, file, added], selected: [file, folder]))
        #expect(plan.action == .items([.init(folder), .init(file)]))
        // a link has no hash: its target is its content, so it is restored like a file
        var link = Rules.entry("BackupMe/link", kind: .symlink)
        link.linkTarget = "../README.md"
        #expect(RestorePlanner.resolve(browsing(visible: [link], selected: [link])).action == .items([.init(link)]))
    }

    @Test func aRowTheFilterHidesIsNotSelected() {
        // both were selected, then a filter hid the file: only the folder is still selected
        let plan = RestorePlanner.resolve(browsing(visible: [folder], selected: [file, folder]))
        #expect(plan.action == .items([.init(folder)]))
    }

    @Test func anAddedItemRestoresNothing() {
        #expect(RestorePlanner.resolve(browsing(visible: [added, file], selected: [added])).action == .nothing)
        // chosen together with a real one, only the real one is restored
        #expect(RestorePlanner.resolve(browsing(visible: [added, file], selected: [added, file])).action == .items([.init(file)]))
    }

    @Test func aSavedFolderAsksFirst() {
        let selected = RestorePlanner.resolve(browsing(source: nil, path: "", visible: [saved], selected: [saved]))
        #expect(selected.action == .wholeFolder(source))
        #expect(selected.asksFirst)
        // at the root of a saved folder with nothing selected, the folder itself is what gets restored
        let here = RestorePlanner.resolve(browsing(path: "", visible: [folder, file], selected: []))
        #expect(here.action == .wholeFolder(source))
        #expect(here.asksFirst)
    }

    @Test func twoSavedFoldersRestoreBesideWithoutAsking() {
        let plan = RestorePlanner.resolve(browsing(source: nil, path: "", visible: [saved, savedOther], selected: [saved, savedOther]))
        #expect(plan.action == .items([.init(saved), .init(savedOther)]))
        #expect(!plan.asksFirst)
    }

    @Test func atTheTopLevelWithNothingSelectedEverythingIsRestored() {
        let plan = RestorePlanner.resolve(browsing(source: nil, path: "", visible: [saved, savedOther], selected: []))
        #expect(plan.action == .wholeBackup)
        #expect(plan.from == backup)
    }

    @Test func theChosenVersionComesFromItsOwnBackup() {
        let plan = RestorePlanner.resolve(browsing(visible: [file], selected: [file], version: .init(backup: older, entry: file)))
        #expect(plan.action == .version(.init(file)))
        #expect(plan.from == older)
        #expect(plan.isVersion)
        // the browsed backup's own version is not another version: the file is simply restored from it
        let own = RestorePlanner.resolve(browsing(visible: [file], selected: [file], version: .init(backup: backup, entry: file)))
        #expect(own.action == .items([.init(file)]))
        #expect(own.from == backup)
        #expect(!own.isVersion)
    }

    @Test func aVersionOfAnotherFileIsIgnored() {
        let plan = RestorePlanner.resolve(browsing(visible: [file], selected: [file], version: .init(backup: older, entry: Rules.entry("BackupMe/Altro.md"))))
        #expect(plan.action == .items([.init(file)]))
        #expect(plan.from == backup)
        #expect(!plan.isVersion)
    }

    @Test func aFolderHasNoVersion() {
        // the same path held as a file by another backup: a folder row never becomes a version
        let plan = RestorePlanner.resolve(browsing(visible: [folder], selected: [folder],
                                                   version: .init(backup: older, entry: Rules.entry("BackupMe", size: 15_000))))
        #expect(plan.action == .items([.init(folder)]))
        #expect(plan.from == backup)
    }

    @Test func aSearchResult() {
        let hit = RestorePlanner.Hit(backup: older, entry: file)
        let plan = RestorePlanner.resolve(RestorePlanner.Selection(backup: backup, searching: true, hit: hit))
        #expect(plan.action == .items([.init(file)]))
        // the result is restored from the backup that holds it, not from the one being browsed
        #expect(plan.from == older)
        let versioned = RestorePlanner.resolve(RestorePlanner.Selection(backup: backup, searching: true, hit: hit,
                                                                        version: .init(backup: backup, entry: file)))
        #expect(versioned.action == .version(.init(file)))
        #expect(versioned.from == backup)
        #expect(versioned.isVersion)
        // before any backup is browsed (its index still loads), a result is restored all the same
        let early = RestorePlanner.resolve(RestorePlanner.Selection(searching: true, hit: hit))
        #expect(early.action == .items([.init(file)]))
        #expect(early.from == older)
        // a version held by the result's own backup is the result itself
        #expect(RestorePlanner.resolve(RestorePlanner.Selection(backup: backup, searching: true, hit: hit,
                                                              version: .init(backup: older, entry: file))).action == .items([.init(file)]))
    }

    @Test func aSearchWithNothingSelectedRestoresNothing() {
        #expect(RestorePlanner.resolve(RestorePlanner.Selection(backup: backup, searching: true)).action == .nothing)
    }

    @Test func theBarOfAFile() {
        let selection = browsing(visible: [file], selected: [file])
        #expect(bar(selection) == .init(icon: .file, name: "README.md", detail: "dal backup di ieri alle 15:00", buttons: [.preview, .restore]))
        #expect(bar(selection, compare: true) == .init(icon: .file, name: "README.md", detail: "dal backup di ieri alle 15:00",
                                                        buttons: [.preview, .compare, .restore]))
    }

    @Test func theBarOfAFolderAndOfTheFolderBeingViewed() {
        let selected = browsing(path: "BackupMe/Sources", visible: [folder], selected: [folder])
        #expect(bar(selected) == .init(icon: .folder, name: "BackupMe", detail: "dal backup di ieri alle 15:00", buttons: [.restore]))
        let none = browsing(path: "BackupMe/Sources", visible: [folder], selected: [])
        #expect(bar(none) == .init(icon: .folder, name: "Sources", detail: "dal backup di ieri alle 15:00", buttons: [.restore]))
    }

    @Test func theBarOfSeveralItems() {
        let selection = browsing(visible: [folder, file], selected: [folder, file])
        #expect(bar(selection) == .init(icon: .stack, name: "2 elementi", detail: "1 cartella e 1 file · 15 kB · dal backup di ieri alle 15:00",
                                        buttons: [.restore]))
    }

    @Test func theBarOfAVersion() {
        let selection = browsing(visible: [file], selected: [file], version: .init(backup: older, entry: file))
        #expect(bar(selection) == .init(icon: .file, name: "README.md", detail: "versione del 30 ott, 20:00", buttons: [.preview, .restore]))
        #expect(bar(selection, compare: true) == .init(icon: .file, name: "README.md", detail: "versione del 30 ott, 20:00",
                                                        buttons: [.preview, .compare, .restore]))
        // the bar names a version only when it comes from another backup than the one being viewed
        let own = browsing(visible: [file], selected: [file], version: .init(backup: backup, entry: file))
        #expect(bar(own) == .init(icon: .file, name: "README.md", detail: "dal backup di ieri alle 15:00", buttons: [.preview, .restore]))
    }

    @Test func theBarOfASavedFolderAndOfAllOfThem() {
        let one = browsing(source: nil, path: "", visible: [saved], selected: [saved])
        #expect(bar(one) == .init(icon: .folder, name: "Progetti", detail: "cartella intera · dal backup di ieri alle 15:00", buttons: [.restore]))
        let all = browsing(source: nil, path: "", visible: [saved, savedOther], selected: [])
        #expect(bar(all) == .init(icon: .drive, name: "Tutte le cartelle", detail: "2 cartelle · dal backup di ieri alle 15:00", buttons: [.restoreAll]))
        var single = browsing(source: nil, path: "", visible: [saved], selected: [])
        single.sources = [source]
        #expect(bar(single) == .init(icon: .drive, name: "Tutte le cartelle", detail: "1 cartella · dal backup di ieri alle 15:00", buttons: [.restoreAll]))
    }

    @Test func thePlanListsWhatItRestores() {
        #expect(RestorePlanner.resolve(browsing(visible: [folder, file], selected: [folder, file])).items == [.init(folder), .init(file)])
        #expect(RestorePlanner.resolve(browsing(source: nil, path: "", visible: [saved], selected: [saved])).items == [.init(source: source, path: "")])
        #expect(RestorePlanner.resolve(browsing(source: nil, path: "", visible: [saved], selected: [])).items.isEmpty)
        #expect(RestorePlanner.resolve(browsing(visible: [file], selected: [file], version: .init(backup: older, entry: file))).items == [.init(file)])
        #expect(RestorePlanner.resolve(RestorePlanner.Selection()).items.isEmpty)
    }

    @Test func theBarWhenNothingCanBeRestored() {
        #expect(bar(browsing(visible: [added], selected: [added])) == .init(icon: .none, name: "Niente da ripristinare qui", detail: "", buttons: [.reveal]))
        #expect(bar(RestorePlanner.Selection(backup: backup, searching: true)) == .init(icon: .none, name: "Seleziona un risultato", detail: "", buttons: [.reveal]))
    }
}

@Suite struct SelectionSummaryTests {
    @Test func countsFoldersThenFilesThenTheSizeOfTheFiles() {
        let folder = Rules.entry("a", kind: .directory), file = Rules.entry("b", size: 2_400_000), link = Rules.entry("c", kind: .symlink)
        #expect(SelectionSummary.text([folder, file, link], locale: Rules.it) == "1 cartella e 2 file · 2,4 MB")
        #expect(SelectionSummary.text([file], locale: Rules.it) == "1 file · 2,4 MB")
        #expect(SelectionSummary.text([folder, folder], locale: Rules.it) == "2 cartelle")
        #expect(SelectionSummary.text([link], locale: Rules.it) == "1 file")
    }

    @Test func saysHowManyAreSelected() {
        #expect(SelectionSummary.count(1) == "1 elemento selezionato")
        #expect(SelectionSummary.count(3) == "3 elementi selezionati")
    }
}
```

- [ ] **Step 2: Lanciarli e vederli fallire.**

Run: `swift test --filter "BackupTimelineTests|WhenTextTests|RestorePlannerTests|SelectionSummaryTests|RowFilterTests"`
Expected: `error: cannot find type 'RestorePlanner' in scope`

- [ ] **Step 3: Scrivere la regola.** Creare `Sources/RestoreRules/RestorePlanner.swift`:

```swift
import BackupCore
import Foundation

/// The line the inspector and the bar give to several selected items.
public enum SelectionSummary {
    /// "3 elementi selezionati", "1 elemento selezionato".
    public static func count(_ n: Int) -> String { n == 1 ? "1 elemento selezionato" : "\(n) elementi selezionati" }

    /// "2 cartelle e 1 file · 2,4 MB": the folders, then the files, then the size of the files when there is one.
    public static func text(_ entries: [Entry], locale: Locale = Locale(identifier: "it_IT")) -> String {
        let folders = entries.filter { $0.kind == .directory }.count
        let files = entries.count - folders
        let size = entries.filter { $0.kind == .file }.reduce(Int64(0)) { $0 + $1.size }
        var parts: [String] = []
        if folders > 0 { parts.append(folders == 1 ? "1 cartella" : "\(folders) cartelle") }
        if files > 0 { parts.append(files == 1 ? "1 file" : "\(files) file") }
        var text = parts.joined(separator: " e ")
        if !parts.isEmpty, size > 0 { text += " · " + BackupTimeline.bytesText(size, locale: locale) }
        return text
    }
}

/// What tells a row from another: the saved folder it comes from and its path in it.
public extension Entry {
    var restoreID: String { source + "\u{0}" + path }
    /// A file or a link always has its content in the index: one without it is on disk today and not in the backup.
    var hasContent: Bool { kind == .directory || hash != nil || linkTarget != nil }
}

/// Says what «Ripristina» acts on, and what the bar tells about it.
public enum RestorePlanner {
    public struct Backup: Equatable, Sendable {
        public var id: String
        public var date: Date
        public init(id: String, date: Date) { self.id = id; self.date = date }
    }

    /// A file as a search result, or as one of its saved versions.
    public struct Hit: Equatable, Sendable {
        public var backup: Backup
        public var entry: Entry
        public init(backup: Backup, entry: Entry) { self.backup = backup; self.entry = entry }
    }

    /// What the window has selected.
    public struct Selection: Equatable, Sendable {
        /// The backup being browsed; nil until it is loaded.
        public var backup: Backup?
        public var searching = false
        /// The selected search result.
        public var hit: Hit?
        /// nil at «Tutte le cartelle», where the rows are the saved folders.
        public var source: String?
        /// "" at the root of a saved folder.
        public var path = ""
        /// The rows the list shows, after the filter.
        public var visible: [Entry] = []
        /// The selected rows: one the filter hides isn't selected any more.
        public var selectedIDs: Set<String> = []
        /// The chosen version of the only selected file.
        public var version: Hit?
        /// The saved folders of the backup.
        public var sources: [String] = []

        public init(backup: Backup? = nil, searching: Bool = false, hit: Hit? = nil, source: String? = nil, path: String = "",
                    visible: [Entry] = [], selectedIDs: Set<String> = [], version: Hit? = nil, sources: [String] = []) {
            self.backup = backup; self.searching = searching; self.hit = hit; self.source = source; self.path = path
            self.visible = visible; self.selectedIDs = selectedIDs; self.version = version; self.sources = sources
        }
    }

    public struct Item: Equatable, Sendable {
        public var source: String
        public var path: String
        /// nil for the folder being viewed.
        public var entry: Entry?
        public init(source: String, path: String, entry: Entry? = nil) { self.source = source; self.path = path; self.entry = entry }
        public init(_ entry: Entry) { self.init(source: entry.source, path: entry.path, entry: entry) }
    }

    public struct Plan: Equatable, Sendable {
        public enum Action: Equatable, Sendable {
            /// Nothing to restore: the button is off.
            case nothing
            /// Beside the original.
            case items([Item])
            /// The chosen version.
            case version(Item)
            /// A whole saved folder: it asks first.
            case wholeFolder(String)
            /// Every saved folder, into a folder of choice.
            case wholeBackup
        }

        public var action: Action
        /// The backup the restore reads from.
        public var from: Backup?
        /// `from` holds a chosen version, not the backup being browsed or the result's.
        public var isVersion: Bool { if case .version = action { return true }; return false }
        /// A whole saved folder asks before anything is written.
        public var asksFirst: Bool { if case .wholeFolder = action { return true }; return false }

        /// What the action restores, the saved folders included; nothing for `.nothing` and `.wholeBackup`.
        public var items: [Item] {
            switch action {
            case .nothing, .wholeBackup: []
            case .items(let items): items
            case .version(let item): [item]
            case .wholeFolder(let source): [Item(source: source, path: "")]
            }
        }

        init(action: Action, from: Backup?) { self.action = action; self.from = from }
    }

    /// The same rules as ever: what is selected is what gets restored, beside the original, and a whole saved folder asks first.
    public static func resolve(_ s: Selection) -> Plan {
        // a result stands on its own: it is restored even while no backup is browsed yet (its index still loads)
        if s.searching {
            guard let hit = s.hit else { return Plan(action: .nothing, from: nil) }
            if let v = otherVersion(s.version, of: hit.entry, than: hit.backup) {
                return Plan(action: .version(Item(v.entry)), from: v.backup)
            }
            return Plan(action: .items([Item(hit.entry)]), from: hit.backup)
        }
        guard let backup = s.backup else { return Plan(action: .nothing, from: nil) }
        // a row without content («Nuovo») is on disk today and not in the backup: nothing comes back from it
        let restorable = s.visible.filter { s.selectedIDs.contains($0.restoreID) && $0.hasContent }
        if restorable.count == 1, let v = otherVersion(s.version, of: restorable[0], than: backup) {
            return Plan(action: .version(Item(v.entry)), from: v.backup)
        }
        if !restorable.isEmpty {
            if restorable.count == 1, restorable[0].path.isEmpty { return Plan(action: .wholeFolder(restorable[0].source), from: backup) }
            return Plan(action: .items(restorable.map { Item($0) }), from: backup)
        }
        // only rows without content are selected, or none inside the folder being viewed
        let picked = s.visible.contains { s.selectedIDs.contains($0.restoreID) }
        guard !picked, let source = s.source else {
            return picked ? Plan(action: .nothing, from: nil) : Plan(action: .wholeBackup, from: backup)
        }
        if s.path.isEmpty { return Plan(action: .wholeFolder(source), from: backup) }
        return Plan(action: .items([Item(source: source, path: s.path)]), from: backup)
    }

    /// The chosen version of the one file `entry`, when a backup other than `own` holds it: that backup's own version is not another version.
    private static func otherVersion(_ v: Hit?, of entry: Entry, than own: Backup) -> Hit? {
        guard let v, entry.kind == .file, v.backup.id != own.id, v.entry.source == entry.source, v.entry.path == entry.path else { return nil }
        return v
    }

    /// What the bar shows.
    public struct Bar: Equatable, Sendable {
        public enum Icon: Hashable, Sendable { case none, file, folder, stack, drive }
        public enum Button: Hashable, Sendable { case preview, compare, reveal, restore, restoreAll }
        public var icon: Icon
        public var name: String
        /// «dal backup di ieri alle 15:00», «versione del 30 ott, 20:00», or «2,4 MB · dal backup di …».
        public var detail: String
        public var buttons: [Button]
    }

    /// The bar for a plan. `compare`: the file differs from today's, so the two can be put side by side.
    public static func bar(_ plan: Plan, selection s: Selection, compare: Bool, now: Date = Date(), calendar: Calendar = .current,
                           locale: Locale = Locale(identifier: "it_IT")) -> Bar {
        let from = plan.from.map { WhenText.from($0.date, now: now, calendar: calendar, locale: locale) } ?? ""
        var fileButtons: [Bar.Button] = [.preview]
        if compare { fileButtons.append(.compare) }
        fileButtons.append(.restore)
        switch plan.action {
        case .nothing:
            // nothing comes back, but where the items are today can still be shown
            return Bar(icon: .none, name: s.searching ? "Seleziona un risultato" : "Niente da ripristinare qui", detail: "", buttons: [.reveal])
        case .wholeBackup:
            let n = s.sources.count
            return Bar(icon: .drive, name: "Tutte le cartelle",
                       detail: (n == 1 ? "1 cartella" : "\(n) cartelle") + (from.isEmpty ? "" : " · " + from), buttons: [.restoreAll])
        case .wholeFolder(let source):
            return Bar(icon: .folder, name: (source as NSString).lastPathComponent,
                       detail: "cartella intera" + (from.isEmpty ? "" : " · " + from), buttons: [.restore])
        case .version(let item):
            return Bar(icon: .file, name: item.entry?.name ?? (item.path as NSString).lastPathComponent,
                       detail: plan.from.map { WhenText.version($0.date, now: now, calendar: calendar, locale: locale) } ?? "",
                       buttons: fileButtons)
        case .items(let items):
            if items.count == 1 {
                let item = items[0]
                if let e = item.entry {
                    if e.kind == .file { return Bar(icon: .file, name: e.name, detail: from, buttons: fileButtons) }
                    return Bar(icon: .folder, name: e.name, detail: from, buttons: [.restore])
                }
                // the folder being viewed, with nothing selected inside it
                return Bar(icon: .folder, name: (item.path as NSString).lastPathComponent, detail: from, buttons: [.restore])
            }
            return Bar(icon: .stack, name: items.count == 1 ? "1 elemento" : "\(items.count) elementi",
                       detail: SelectionSummary.text(items.compactMap(\.entry), locale: locale) + " · " + from, buttons: [.restore])
        }
    }
}
```

- [ ] **Step 4: Lanciare i test e vederli passare.**

Run: `swift test --filter "BackupTimelineTests|WhenTextTests|RestorePlannerTests|SelectionSummaryTests|RowFilterTests"`
Expected: `Test run with 40 tests in 4 suites passed`

- [ ] **Step 5: L'intera suite.**

Run: `swift test 2>&1 | tail -3`
Expected: `Test run with 363 tests in 34 suites passed after … seconds.` (i 323 di prima e i 40 nuovi; se fallisce solo `snapshotOnFATFilesystems`, vedi Review Focus 7 e rilancialo da solo).

- [ ] **Step 6: Commit**

```bash
git add Sources/RestoreRules/RestorePlanner.swift Tests/BackupCoreTests/RestorePlannerTests.swift
git commit -m "feat(app): le regole di ciò che Ripristina ripristina in Sfoglia, provate"
```

---

### Task 4: La vista `RestoreTimeline`

Da qui all'Task 8 la finestra vecchia resta al suo posto e compila accanto ai file nuovi: i file nuovi non sono ancora usati da nessuno.

**Files:**
- Create: `Sources/BackupMe/RestoreTimeline.swift`

**Interfaces — Produces:**

```swift
struct RestoreTimeline: View {
    let model: RestoreModel
    let items: [TimelineItem]                 // every backup, newest first
    let reveal: Int                           // bumped to scroll to the chosen backup
    let showStatus: Bool
    let statusText: String
    let statusColor: Color
    let statusSymbol: String
    let locale: Locale
    let choose: (String) -> Void              // shows a backup and leaves the search
    init(model: RestoreModel, items: [TimelineItem], reveal: Int, showStatus: Bool, statusText: String,
         statusColor: Color, statusSymbol: String, locale: Locale, choose: @escaping (String) -> Void)
}
```

- [ ] **Step 1: Creare** `Sources/BackupMe/RestoreTimeline.swift`:

```swift
import BackupCore
import RestoreRules
import SwiftUI

/// The sidebar: how the last backup went, then every backup as a point on a vertical line.
struct RestoreTimeline: View {
    let model: RestoreModel
    /// Every backup, newest first, with what is known about it.
    let items: [TimelineItem]
    /// Bumped to bring the chosen backup into view when the choice comes from outside the list (shortcuts, «Mostra nel backup»): a click needs no scroll.
    let reveal: Int
    /// The app's history says nothing about another computer's archive: no status line there.
    let showStatus: Bool
    let statusText: String
    let statusColor: Color
    let statusSymbol: String
    let locale: Locale
    /// Shows a backup and leaves the search.
    let choose: (String) -> Void

    private var calendar: Calendar { .current }

    var body: some View {
        let sections = BackupTimeline.sections(items, calendar: calendar, locale: locale)
        ScrollViewReader { proxy in
            List {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.items) { item in row(item) }
                    } header: { header(section) }
                }
            }
            .listStyle(.sidebar)
            .scrollDisabled(sections.isEmpty)
            .safeAreaInset(edge: .top, spacing: 0) {
                if showStatus, !statusText.isEmpty { statusCard }
            }
            .onChange(of: reveal) { _, _ in
                if let id = model.selectedID { proxy.scrollTo(id, anchor: .center) }
            }
            .overlay {
                if model.isLoading, model.hasDestination { ProgressView() }
                else if items.isEmpty, model.hasDestination, model.notConnectedText == nil {
                    ContentUnavailableView("Nessun backup", systemImage: "externaldrive.badge.questionmark",
                                           description: Text("Compariranno qui dopo il primo salvataggio."))
                }
            }
        }
    }

    /// The panel's status line again, where the backups are read.
    private var statusCard: some View {
        Button { if let newest = items.first?.id { choose(newest) } } label: {
            HStack(spacing: 9) {
                Image(systemName: statusSymbol).font(.system(size: 12, weight: .bold)).foregroundStyle(statusColor).frame(width: 16)
                Text(statusText).font(.callout).lineLimit(2).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 11))
        .padding(.horizontal, 10).padding(.bottom, 6)
        .help("Va all'ultimo backup. " + statusText)
        .accessibilityLabel("Va all'ultimo backup")
        .accessibilityValue(statusText)
    }

    private func header(_ section: TimelineSection) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(section.title).textCase(.uppercase)
            Spacer()
            if let bytes = section.newBytes { Text("+" + BackupTimeline.bytesText(bytes, locale: locale)).monospacedDigit() }
        }
        .help("Dati nuovi salvati da questi backup")
    }

    private func row(_ item: TimelineItem) -> some View {
        let selected = model.selectedID == item.id
        let warned = (item.warnings ?? 0) > 0
        let tip = BackupTimeline.detail(item, calendar: calendar, locale: locale)
        // the selected row is one filled capsule, so its line, point and bar are white
        let line = selected ? Color.white.opacity(0.45) : Color.secondary.opacity(0.3)
        let tint: Color = selected ? .white : warned ? .orange : Color.secondary.opacity(0.6)
        return Button { choose(item.id) } label: {
            HStack(spacing: 0) {
                // the line every point sits on, one row at a time: the rows touch, so it reads as one line
                Rectangle().fill(line).frame(width: 1.5).frame(maxHeight: .infinity)
                    .overlay {
                        Circle()
                            .fill(selected ? Color.white : warned ? Color.orange.opacity(0.35) : Color(nsColor: .controlBackgroundColor))
                            .overlay(Circle().strokeBorder(selected ? Color.clear : tint, lineWidth: 1.5))
                            .frame(width: 8, height: 8)
                    }
                    .frame(width: 24)
                Text(BackupTimeline.hourLabel(item.date, calendar: calendar, locale: locale))
                    .font(.callout.weight(selected ? .semibold : .regular)).monospacedDigit()
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .frame(width: 44, alignment: .leading)
                Bar(fraction: BackupTimeline.barWidth(item, in: items), tint: tint,
                    track: selected ? Color.white.opacity(0.25) : Color.secondary.opacity(0.15))
                    .padding(.trailing, 8)
                Text(BackupTimeline.barLabel(item, locale: locale)).font(.caption).monospacedDigit()
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                    .frame(width: 60, alignment: .trailing)
                Image(systemName: warned ? "exclamationmark.triangle.fill" : "circle")
                    .font(.caption2).foregroundStyle(selected ? Color.white : Color.orange)
                    .opacity(warned ? 1 : 0).frame(width: 14)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .listRowSeparator(.hidden)
        .listRowBackground(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor : Color.clear))
        .help(tip)
        .accessibilityLabel(tip) // the label alone is only an hour
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The data a backup saved, against the largest one; nothing at all when unknown.
private struct Bar: View {
    let fraction: Double?
    let tint: Color
    let track: Color

    var body: some View {
        if let fraction {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(track)
                    if fraction > 0 { Capsule().fill(tint).frame(width: max(3, g.size.width * fraction)) }
                }
            }
            .frame(height: 5)
        } else {
            Color.clear.frame(height: 5).frame(maxWidth: .infinity)
        }
    }
}
```

- [ ] **Step 2: Compilare.**

Run: `swift build --product BackupMe`
Expected: `Build complete!`

- [ ] **Step 3: I test restano verdi.**

Run: `swift test 2>&1 | tail -3`
Expected: `Test run with 363 tests in 34 suites passed`

- [ ] **Step 4: Commit**

```bash
git add Sources/BackupMe/RestoreTimeline.swift
git commit -m "feat(app): la vista della linea del tempo in Sfoglia"
```

---

### Task 5: La vista `RestoreBrowser`

**Files:**
- Test: `Tests/BackupCoreTests/RowFilterTests.swift`
- Create: `Sources/RestoreRules/ChangeFilter.swift`
- Modify: `Sources/BackupMe/RestoreModel.swift` (un import, via due tipi, `matches`)
- Modify: `Sources/BackupMe/RestoreView.swift` (un import, e via il vecchio `FileIcon`)
- Create: `Sources/BackupMe/RestoreBrowser.swift`

`ChangeFilter` e `RowStatus` nascevano nell'app. La regola «questa riga passa quel filtro» va provata, e i test non arrivano all'app: i due tipi piccoli si spostano in `RestoreRules` insieme alla regola. Senza, il tag «Tutto» contava gli eliminati.

`RestoreBrowser.swift` dichiara `FileIcon` interno, e la finestra vecchia ne ha uno privato con lo stesso nome: nello stesso modulo è una ridichiarazione. Si toglie quello vecchio; la finestra vecchia usa quello nuovo, che ha la stessa firma.

**Interfaces — Produces:**

```swift
// RestoreRules
public enum ChangeFilter: String, CaseIterable, Sendable { case all, modified, missing, added }
public struct RowStatus: Equatable, Sendable {
    public var own: EntryStatus; public var modifiedInside: Bool; public var missingInside: Bool
    public init(own: EntryStatus, modifiedInside: Bool = false, missingInside: Bool = false)
    public func passes(_ filter: ChangeFilter) -> Bool   // «Tutto» prende ogni riga; nessuna riga del backup è «Nuovo»
}
// RestoreModel
func matches(_ e: Entry, _ f: ChangeFilter) -> Bool     // «Nuovi» chiede a isAdded, gli altri allo stato

struct RestoreActions {
    var enter: (Entry) -> Void
    var preview: (Entry) -> Void
    var restore: (String, [(source: String, path: String)]) -> Void
    var restoreInto: (String, [(source: String, path: String)]) -> Void
    var compare: (Entry) -> Void
    var reveal: (SearchHit) -> Void
    var quickLook: () -> Bool
    var dragProvider: (Entry) -> NSItemProvider?
}
struct RestoreBrowser: View {
    let model: RestoreModel; let items: [TimelineItem]; let rows: [Entry]; let results: [SearchHit]; let actions: RestoreActions
    @Binding var filter: ChangeFilter; @Binding var deletedOnly: Bool
    @Binding var selectedIDs: Set<Entry.ID>; @Binding var hit: SearchHit?; @Binding var showInspector: Bool
    @Binding var sortOrder: [KeyPathComparator<Entry>]; @Binding var columns: TableColumnCustomization<Entry>
    let locale: Locale
}
struct StatusBadge: View {
    init(_ text: String, color: Color)
    static func change(_ s: RowStatus?, added: Bool, since: Bool) -> StatusBadge?   // nil when nothing changed
}
@MainActor enum FileIcon { static func image(for e: Entry) -> NSImage }
```

**Interfaces — Consumes:** `TimelineItem`, `WhenText.title`, `WhenText.subtitle` (Task 1–2).

- [ ] **Step 1: Scrivere i test che devono fallire.** Creare `Tests/BackupCoreTests/RowFilterTests.swift`:

```swift
import Testing
@testable import BackupCore
@testable import RestoreRules

@Suite struct RowFilterTests {
    let changed = RowStatus(own: .modified), same = RowStatus(own: .unchanged), gone = RowStatus(own: .missing)
    let holdsChanged = RowStatus(own: .unchanged, modifiedInside: true), holdsGone = RowStatus(own: .unchanged, missingInside: true)

    @Test func modifiedAndDeletedLookAtTheStatus() {
        #expect(changed.passes(.modified) && !changed.passes(.missing))
        #expect(gone.passes(.missing) && !gone.passes(.modified))
        // a folder counts when something inside it changed or vanished
        #expect(holdsChanged.passes(.modified) && !holdsChanged.passes(.missing))
        #expect(holdsGone.passes(.missing) && !holdsGone.passes(.modified))
        #expect(!same.passes(.modified) && !same.passes(.missing))
    }

    @Test func everythingPassesTuttoAndNoRowOfTheBackupIsNew() {
        // «Tutto» once counted the deletions: its number was that of «Eliminati»
        for s in [changed, same, gone, holdsChanged, holdsGone] {
            #expect(s.passes(.all))
            #expect(!s.passes(.added))
        }
    }
}
```

- [ ] **Step 2: Lanciarli e vederli fallire.**

Run: `swift test --filter "BackupTimelineTests|WhenTextTests|RestorePlannerTests|SelectionSummaryTests|RowFilterTests"`
Expected: `error: cannot find type 'RowStatus' in scope`

- [ ] **Step 3: Scrivere la regola.** Creare `Sources/RestoreRules/ChangeFilter.swift`:

```swift
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
```

- [ ] **Step 4: Lanciare i test e vederli passare.**

Run: `swift test --filter "BackupTimelineTests|WhenTextTests|RestorePlannerTests|SelectionSummaryTests|RowFilterTests"`
Expected: `Test run with 42 tests in 5 suites passed`

- [ ] **Step 5: Il modello,** in `Sources/BackupMe/RestoreModel.swift`:
  - aggiungere `import RestoreRules` subito dopo `import Foundation`;
  - cancellare le due dichiarazioni che stanno sotto `struct SearchHit`: `struct RowStatus { … }` con la sua riga di commento, ed `enum ChangeFilter { … }` (ora vengono da `RestoreRules`);
  - subito dopo la riga `func isAdded(_ e: Entry) -> Bool { … }` inserire (con una riga vuota prima):

```swift
    /// A row against a filter: «Nuovi» is for today's files the backup lacks, so a row of the backup never is one.
    func matches(_ e: Entry, _ f: ChangeFilter) -> Bool {
        switch f {
        case .all: true
        case .added: isAdded(e)
        case .modified, .missing: status(of: e)?.passes(f) ?? false
        }
    }
```

- [ ] **Step 6: La finestra vecchia,** in `Sources/BackupMe/RestoreView.swift`. Prima aggiungere `import RestoreRules` subito dopo `import QuickLook`: la finestra usa `ChangeFilter` e `RowStatus`, che ora stanno lì. Poi togliere in fondo al file il vecchio `FileIcon`: questo blocco e la riga vuota che lo segue (righe 803–816 prima dell'import, 804–817 dopo):

```swift
/// One NSWorkspace lookup per extension: the table asks for an icon on every redraw.
@MainActor private enum FileIcon {
    static var cache: [String: NSImage] = [:]

    static func image(for e: Entry) -> NSImage {
        let key = e.kind == .directory ? "/" : e.kind == .symlink ? "@" : (e.name as NSString).pathExtension.lowercased()
        if let image = cache[key] { return image }
        let type: UTType = e.kind == .directory ? .folder : e.kind == .symlink ? .symbolicLink : UTType(filenameExtension: key) ?? .data
        let image = NSWorkspace.shared.icon(for: type)
        cache[key] = image
        return image
    }
}
```

Restano, in fondo a `RestoreView.swift`, `private struct StatusPill`, `private struct EntryInspector`, l'estensione `hidingToolbarTitle` e `extension Entry: Identifiable`.

- [ ] **Step 7: Creare** `Sources/BackupMe/RestoreBrowser.swift`:

```swift
import AppKit
import BackupCore
import RestoreRules
import SwiftUI
import UniformTypeIdentifiers

/// What the list can ask the window to do.
struct RestoreActions {
    var enter: (Entry) -> Void
    var preview: (Entry) -> Void
    /// From a backup, beside the originals.
    var restore: (String, [(source: String, path: String)]) -> Void
    /// From a backup, into a folder of choice.
    var restoreInto: (String, [(source: String, path: String)]) -> Void
    var compare: (Entry) -> Void
    /// Leaves the search and opens the folder holding a result, the file selected.
    var reveal: (SearchHit) -> Void
    /// Space in the list: Quick Look of the selected file, or close it. False when there is nothing to show.
    var quickLook: () -> Bool
    var dragProvider: (Entry) -> NSItemProvider?
}

/// The middle column: the title, the filters and the list of files.
struct RestoreBrowser: View {
    let model: RestoreModel
    /// Every backup with what is known about it: the title speaks of the chosen one.
    let items: [TimelineItem]
    /// The rows the list shows, filter and sort applied.
    let rows: [Entry]
    /// The search results left by the scope.
    let results: [SearchHit]
    let actions: RestoreActions
    @Binding var filter: ChangeFilter
    @Binding var deletedOnly: Bool
    @Binding var selectedIDs: Set<Entry.ID>
    @Binding var hit: SearchHit?
    @Binding var showInspector: Bool
    @Binding var sortOrder: [KeyPathComparator<Entry>]
    @Binding var columns: TableColumnCustomization<Entry>
    let locale: Locale
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            heading
            Divider()
            Group { if model.search.isEmpty { table } else { resultsTable } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: title and filters

    @ViewBuilder private var heading: some View {
        if model.search.isEmpty {
            if let s = model.selected, let item = items.first(where: { $0.id == s.id }) {
                title("Stai guardando il backup di", WhenText.title(s.date, locale: locale),
                      WhenText.subtitle(item, locale: locale))
                // comparing with this Mac's disk is meaningless for another computer's archive
                if model.showsStatus { tags }
            }
        } else {
            let n = results.count
            title("Ricerca in tutti i backup", "«\(model.search)»",
                  (n == 1 ? "1 risultato" : "\(n) risultati") + (model.resultsTruncated ? " (i primi 500)" : ""))
            HStack(spacing: 6) {
                scope(false)
                if model.showsStatus { scope(true) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.bottom, 10)
        }
    }

    private func title(_ eyebrow: String, _ big: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(eyebrow).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Text(big).font(.system(size: 26, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
            Text(sub).font(.callout).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }

    private var tags: some View {
        HStack(spacing: 6) {
            ForEach(ChangeFilter.allCases, id: \.self) { f in
                Button { filter = f } label: {
                    capsule(counted(f), dot: f == .all ? nil : dot(f), on: filter == f)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(filter == f ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.bottom, 10)
        .help("Mostra solo ciò che è cambiato, sparito o comparso dopo questo backup")
    }

    private func scope(_ deleted: Bool) -> some View {
        Button { deletedOnly = deleted } label: {
            capsule(deleted ? "Solo eliminati" : "Tutti", dot: deleted ? Color.red : nil, on: deletedOnly == deleted)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(deletedOnly == deleted ? .isSelected : [])
    }

    /// A filter as a tag: dark when it is the one in use; a pale capsule in Dark Mode, where primary is white.
    private func capsule(_ text: String, dot: Color? = nil, on: Bool) -> some View {
        HStack(spacing: 6) {
            if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
            Text(text).monospacedDigit()
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 10).frame(height: 26)
        .foregroundStyle(on ? Color.white : Color.primary)
        .background(on ? (colorScheme == .dark ? Color.white.opacity(0.28) : Color.primary) : Color.secondary.opacity(0.16), in: Capsule())
        .contentShape(Capsule())
    }

    private func dot(_ f: ChangeFilter) -> Color { f == .added ? .green : f == .modified ? .orange : .red }

    private func counted(_ f: ChangeFilter) -> String {
        let name = f == .all ? "Tutto" : f == .modified ? "Modificati" : f == .missing ? "Eliminati" : "Nuovi"
        guard model.statusReady else { return name }
        // «Nuovi» are kept apart from the rows of the backup: they are counted where they are
        let n = f == .added ? model.added().count : model.children().filter { model.matches($0, f) }.count
        return n == 0 ? name : "\(name) \(n)"
    }

    // MARK: list

    @ViewBuilder private var table: some View {
        if model.isLoading {
            ProgressView()
        } else if model.snapshots.isEmpty {
            ContentUnavailableView("Nessun backup", systemImage: "externaldrive.badge.questionmark",
                                   description: Text("I backup di questo Mac compariranno qui dopo il primo salvataggio."))
        } else if model.selectedID == nil {
            ContentUnavailableView("Scegli un backup", systemImage: "clock.arrow.circlepath",
                                   description: Text("Scegline uno nella barra laterale."))
        } else if model.selected == nil {
            ProgressView() // the chosen backup's index is still loading
        } else {
            fileTable
        }
    }

    private var fileTable: some View {
        Table(of: Entry.self, selection: $selectedIDs, sortOrder: $sortOrder, columnCustomization: $columns) {
            TableColumn("Nome", value: \.name) { e in
                HStack(spacing: 7) { icon(e); Text(e.name).lineLimit(1).truncationMode(.middle) }
            }
            TableColumn("Rispetto a oggi") { e in
                if let b = StatusBadge.change(model.status(of: e), added: model.isAdded(e), since: false) { b }
            }
            .width(min: 90, ideal: 130, max: 170)
            .customizationID("stato")
            TableColumn("Dimensione", value: \.size) { e in
                Text(e.kind == .file ? ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file) : "—")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 70, ideal: 90, max: 120)
            TableColumn("Modificato", value: \.mtime) { e in
                Text(e.mtime.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 120, ideal: 150, max: 200)
        } rows: {
            ForEach(rows) { e in TableRow(e).itemProvider { actions.dragProvider(e) } }
        }
        .contextMenu(forSelectionType: Entry.ID.self) { ids in
            let picked = model.children().filter { ids.contains($0.id) }
            let new = model.added().filter { ids.contains($0.id) }
            if let id = model.selectedID, !picked.isEmpty { rowMenu(snapshotID: id, entries: picked) }
            // items added after the backup have nothing to restore: only where they are today
            else if !new.isEmpty { Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting(new.map(\.url)) } }
        } primaryAction: { ids in
            if let e = model.added().first(where: { ids.contains($0.id) }) {
                NSWorkspace.shared.activateFileViewerSelecting([e.url])
                return
            }
            guard ids.count == 1, let e = model.children().first(where: { ids.contains($0.id) }) else { return }
            if e.kind == .directory { actions.enter(e) } else if e.kind == .file { actions.preview(e) }
        }
        .onKeyPress(.space) { actions.quickLook() ? .handled : .ignored }
        .overlay {
            if filter != .all, model.statusReady, rows.isEmpty {
                ContentUnavailableView(filter == .modified ? "Nessuna modifica" : filter == .missing ? "Nessun elemento eliminato" : "Niente di nuovo",
                                       systemImage: "checkmark.circle",
                                       description: Text("In questa cartella niente è cambiato rispetto a questo backup."))
            } else if filter != .all, !model.statusReady {
                ProgressView("Confronto con oggi…")
            }
        }
    }

    private var resultsTable: some View {
        Table(results, selection: $hit) {
            TableColumn("Nome") { h in
                HStack(spacing: 7) { icon(h.entry); Text(h.entry.name).lineLimit(1) }
            }
            TableColumn("Rispetto a oggi") { h in
                if let b = StatusBadge.change(model.resultStatus[h].map { RowStatus(own: $0) }, added: false, since: false) { b }
            }
            .width(min: 90, ideal: 130, max: 170)
            TableColumn("Percorso") { h in
                Text(((h.entry.source as NSString).lastPathComponent as NSString).appendingPathComponent(h.entry.path))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            TableColumn("Backup del") { h in
                Text(Snapshot.date(fromID: h.snapshotID)?.formatted(date: .abbreviated, time: .shortened) ?? "")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 120, ideal: 150, max: 200)
        }
        .contextMenu(forSelectionType: SearchHit.self) { hits in
            if let h = hits.first {
                Button("Mostra nel backup") { actions.reveal(h) }
                Divider()
                rowMenu(snapshotID: h.snapshotID, entries: [h.entry])
            }
        } primaryAction: { hits in
            if let h = hits.first { actions.reveal(h) }
        }
        .overlay {
            if results.isEmpty, model.busy == nil {
                if deletedOnly {
                    ContentUnavailableView("Nessun file eliminato", systemImage: "magnifyingglass",
                                           description: Text(model.resultsTruncated
                                               ? "Nessuno tra i primi 500 risultati: affina la ricerca per vedere gli altri."
                                               : "Tutto ciò che corrisponde a «\(model.search)» esiste ancora su questo Mac."))
                } else {
                    ContentUnavailableView.search(text: model.search)
                }
            }
        }
    }

    @ViewBuilder private func rowMenu(snapshotID: String, entries: [Entry]) -> some View {
        if entries.count == 1, let e = entries.first {
            if e.kind == .directory, model.search.isEmpty { Button("Apri") { actions.enter(e) } }
            if e.kind == .file { Button("Anteprima") { actions.preview(e) } }
        }
        let items = entries.map { (source: $0.source, path: $0.path) }
        let n = entries.count == 1 ? "" : " \(entries.count) elementi"
        Button("Ripristina\(n)") { actions.restore(snapshotID, items) }
        Button("Ripristina\(n) in…") { actions.restoreInto(snapshotID, items) }
        if entries.count == 1, let e = entries.first, e.kind == .file {
            Divider()
            Button("Mostra versioni del file") {
                // the inspector shows the selection: a right click alone doesn't change it
                if model.search.isEmpty { selectedIDs = [e.id] } else { hit = SearchHit(snapshotID: snapshotID, entry: e) }
                showInspector = true
            }
            if model.showsStatus, Restorer.status(of: e) == .modified {
                Button("Confronta con la versione attuale") { actions.compare(e) }
            }
        }
    }

    // MARK: rows

    private func icon(_ e: Entry) -> some View {
        Image(nsImage: FileIcon.image(for: e)).resizable().frame(width: 20, height: 20)
    }
}

/// Words in a tinted box: the change since this backup reads without hovering.
struct StatusBadge: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color) { self.text = text; self.color = color }

    /// The badge of a row, nil when nothing changed; `since` asks for the inspector's words, that say when ("Modificato da allora").
    static func change(_ s: RowStatus?, added: Bool, since: Bool) -> StatusBadge? {
        if added { return StatusBadge("Nuovo", color: .green) }
        guard let s else { return nil }
        if s.own == .missing { return StatusBadge(since ? "Eliminato da allora" : "Eliminato", color: .red) }
        if s.own == .modified { return StatusBadge(since ? "Modificato da allora" : "Modificato", color: .orange) }
        if s.modifiedInside { return StatusBadge("Contiene modifiche", color: .orange) }
        if s.missingInside { return StatusBadge("Contiene eliminati", color: .red) }
        // only the inspector says of an item that stayed the same that it is like today's
        return since ? StatusBadge("Uguale a oggi", color: .secondary) : nil
    }

    var body: some View {
        Text(text).font(.caption.weight(.medium)).lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 1.5)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// One NSWorkspace lookup per extension: the table asks for an icon on every redraw.
@MainActor enum FileIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(for e: Entry) -> NSImage {
        let key = e.kind == .directory ? "/" : e.kind == .symlink ? "@" : (e.name as NSString).pathExtension.lowercased()
        if let image = cache[key] { return image }
        let type: UTType = e.kind == .directory ? .folder : e.kind == .symlink ? .symbolicLink : UTType(filenameExtension: key) ?? .data
        let image = NSWorkspace.shared.icon(for: type)
        cache[key] = image
        return image
    }
}
```

- [ ] **Step 8: Compilare.**

Run: `swift build --product BackupMe`
Expected: `Build complete!`

- [ ] **Step 9: L'intera suite.**

Run: `swift test 2>&1 | tail -3`
Expected: `Test run with 365 tests in 35 suites passed` (i 323 di prima e i 42 nuovi).

- [ ] **Step 10: Commit**

```bash
git add Sources/RestoreRules/ChangeFilter.swift Tests/BackupCoreTests/RowFilterTests.swift
git add Sources/BackupMe/RestoreModel.swift Sources/BackupMe/RestoreBrowser.swift Sources/BackupMe/RestoreView.swift
git commit -m "feat(app): la vista del titolo, dei filtri e della lista in Sfoglia; la regola dei filtri provata"
```

---

### Task 6: L'ispettore e la copia silenziosa per l'anteprima

**Files:**
- Modify: `Sources/BackupMe/RestoreModel.swift` (una funzione)
- Create: `Sources/BackupMe/RestoreInspector.swift`

**Interfaces — Consumes:** `RestorePlanner.Selection`, `SelectionSummary`, `WhenText.version`, `StatusBadge.change`, `FileIcon` (Task 3 e 5).

**Interfaces — Produces:**

```swift
// RestoreModel
func previewCopy(_ e: Entry) async -> URL?   // nil senza avviso: solo una riga di debug nel registro

struct RestoreInspector: View {
    let model: RestoreModel; let selection: RestorePlanner.Selection
    let status: (Entry) -> RowStatus?; let showsStatus: Bool
    @Binding var picked: SearchHit?
    let locale: Locale
}
```

- [ ] **Step 1: La copia temporanea** in `Sources/BackupMe/RestoreModel.swift`. Sostituire la funzione `extracted` (dal suo commento `/// A read-only temporary copy for Quick Look or comparing…` alla parentesi di chiusura) con: una funzione privata che legge, e due che decidono cosa fare quando la lettura non riesce.

```swift
    /// A read-only temporary copy of a backed-up file.
    private func copy(_ e: Entry) async throws -> URL {
        try await withRepository { try Restorer(repository: $0).extract(e) }
    }

    /// A copy for the inspector's card, which must not interrupt: nil, and a debug line in the log, if it can't be read.
    func previewCopy(_ e: Entry) async -> URL? {
        do { return try await copy(e) } catch {
            Log.restore.debug("Anteprima nell'ispettore non disponibile: \(AppModel.describe(error))")
            return nil
        }
    }

    /// A copy for Quick Look or comparing; nil, with an error shown, if it can't be read.
    func extracted(_ e: Entry) async -> URL? {
        do { return try await copy(e) } catch {
            self.error = ("Anteprima non disponibile", AppModel.describe(error))
            return nil
        }
    }
```



- [ ] **Step 2: Creare** `Sources/BackupMe/RestoreInspector.swift`:

```swift
import AppKit
import BackupCore
import QuickLook
import QuickLookThumbnailing
import RestoreRules
import SwiftUI
import UniformTypeIdentifiers

/// The right-hand panel: the chosen item, its content and its saved versions; information only, the actions are in the bar.
struct RestoreInspector: View {
    let model: RestoreModel
    let selection: RestorePlanner.Selection
    /// A row against this Mac's disk.
    let status: (Entry) -> RowStatus?
    let showsStatus: Bool
    /// The chosen version of the file: what the bar's Anteprima, Confronta and Ripristina act on.
    @Binding var picked: SearchHit?
    let locale: Locale

    private var snapshotID: String? { selection.searching ? selection.hit?.backup.id : selection.backup?.id }

    var body: some View {
        let entries = chosen
        if entries.count == 1, let e = entries.first {
            detail(e).id((snapshotID ?? "") + "\u{0}" + e.restoreID)
        } else if entries.count > 1 {
            ContentUnavailableView {
                Label(SelectionSummary.count(entries.count), systemImage: "square.stack.3d.up")
            } description: {
                VStack(spacing: 4) {
                    Text(SelectionSummary.text(entries, locale: locale))
                    Text("Seleziona un solo file per vederne dettagli e versioni.")
                }
            }
        } else {
            ContentUnavailableView("Nessuna selezione", systemImage: "info.circle",
                                   description: Text("Seleziona un file per vederne dettagli e versioni."))
        }
    }

    /// The selected rows, or the selected search result.
    private var chosen: [Entry] {
        if selection.searching { return selection.hit.map { [$0.entry] } ?? [] }
        return selection.visible.filter { selection.selectedIDs.contains($0.restoreID) }
    }

    private func detail(_ entry: Entry) -> some View {
        let s = status(entry)
        // the window clears the pick when the selection changes, one update later: until then it is nobody's
        let version = picked.flatMap { $0.entry.source == entry.source && $0.entry.path == entry.path ? $0 : nil }
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // the card shows the chosen version: what is seen is what Anteprima and Ripristina use
                if entry.kind == .file, let version {
                    PreviewCard(model: model, entry: version.entry, other: version.snapshotID == snapshotID ? nil : version, locale: locale)
                }
                HStack(spacing: 10) {
                    Image(nsImage: FileIcon.image(for: entry)).resizable().frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.name).font(.headline).lineLimit(2).textSelection(.enabled)
                        if let b = StatusBadge.change(s, added: model.isAdded(entry), since: true) { b }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    if entry.kind == .file { SizeRow(entry: entry, showsStatus: showsStatus) }
                    row("Modificato", entry.mtime.formatted(date: .abbreviated, time: .shortened))
                    row("Posizione", ((entry.source as NSString).abbreviatingWithTildeInPath as NSString)
                        .appendingPathComponent((entry.path as NSString).deletingLastPathComponent))
                }
                if entry.kind == .file {
                    EntryVersions(model: model, entry: entry, snapshotID: snapshotID ?? "", picked: $picked)
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).lineLimit(2).truncationMode(.middle).textSelection(.enabled) }.font(.callout)
    }
}

/// The size in the backup and, for a file still on this Mac, today's.
private struct SizeRow: View {
    let entry: Entry
    let showsStatus: Bool
    @State private var today: Int64?

    var body: some View {
        LabeledContent("Dimensione") {
            Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
                 + (today.map { " allora · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) + " oggi" } ?? ""))
                .monospacedDigit()
        }
        .font(.callout)
        .task(id: entry) {
            guard showsStatus, Restorer.status(of: entry) != .missing else { today = nil; return }
            let url = entry.url
            today = await Task.detached(priority: .utility) { (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) }.value
        }
    }
}

/// Every saved version of the file, one per distinct content, on a line: the chosen one is marked.
private struct EntryVersions: View {
    let model: RestoreModel
    let entry: Entry
    let snapshotID: String
    @Binding var picked: SearchHit?
    @State private var versions: [SearchHit]? // nil while loading
    /// Backups not yet read for versions: they are read only after «Cerca le versioni in tutti i backup».
    @State private var unread = 0
    @State private var searchAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text("Versioni").font(.subheadline.weight(.semibold))
                Spacer()
                if let versions {
                    Text(versions.count == 1 ? "1 salvata" : "\(versions.count) salvate")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if let versions {
                if versions.isEmpty {
                    Text("Nessuna versione leggibile").foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(versions) { v in version(v) }
                    }
                    Text("Una riga per ogni contenuto diverso, dalla più recente.").font(.caption).foregroundStyle(.secondary)
                }
                if unread > 0 {
                    if searchAll {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(unread == 1 ? "Resta 1 backup da leggere…" : "Restano \(unread) backup da leggere…")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Cerca le versioni in tutti i backup") { searchAll = true }
                            .help((unread == 1 ? "Legge l'altro backup" : "Legge gli altri \(unread) backup")
                                  + ": con molti file può richiedere qualche minuto")
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task(id: searchAll) {
            // the backups already open answer at once; the others only on request, as each manifest takes seconds
            await model.versions(of: entry, in: snapshotID, all: searchAll) { list, left in
                let found = list.map { SearchHit(snapshotID: $0.snapshotID, entry: $0.entry) }
                versions = found
                unread = left
                // the pick stays on its content: a newer backup holding it may now name the row
                picked = found.first { $0.entry.hash == picked?.entry.hash } ?? found.first { $0.snapshotID == snapshotID } ?? found.first
            }
        }
    }

    private func version(_ v: SearchHit) -> some View {
        let on = picked == v
        return Button { picked = v } label: {
            HStack(spacing: 0) {
                // the line the versions sit on, one row at a time
                Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 1.5).frame(maxHeight: .infinity)
                    .overlay {
                        Circle().fill(on ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                            .overlay(Circle().strokeBorder(on ? Color.clear : Color.secondary.opacity(0.6), lineWidth: 1.5))
                            .frame(width: 8, height: 8)
                    }
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Snapshot.date(fromID: v.snapshotID)?.formatted(date: .abbreviated, time: .shortened) ?? v.snapshotID)
                        .font(.callout.weight(on ? .semibold : .regular)).monospacedDigit()
                    if v.entry.hash == entry.hash { Text("in questo backup").font(.caption2).foregroundStyle(.secondary) }
                }
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: v.entry.size, countStyle: .file))
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.trailing, 8).padding(.vertical, 3)
            .contentShape(Rectangle())
            .background(on ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The content of the chosen version, read from the archive once.
private struct PreviewCard: View {
    /// Above this the card keeps the icon: selecting a file must never read one of any size.
    static let limit: Int64 = 20_000_000

    enum Content { case image(NSImage), text(String), thumbnail(NSImage) }

    let model: RestoreModel
    let entry: Entry
    /// The version isn't the one of the backup being viewed: the card says which one it is.
    let other: SearchHit?
    let locale: Locale
    @State private var content: Content?

    private var background: some View {
        RoundedRectangle(cornerRadius: 12).fill(LinearGradient(
            colors: [Color(nsColor: .controlBackgroundColor), Color(nsColor: .underPageBackgroundColor)],
            startPoint: .top, endPoint: .bottom))
    }

    private var card: some View {
        ZStack { background; picture }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// What the card shows; the file's icon until something was read.
    @ViewBuilder private var picture: some View {
        switch content {
        case .image(let image): shown(image, inset: 10)
        case .thumbnail(let image): shown(image, inset: 14)
        case .text(let text):
            Text(text).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(30).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
        case nil: Image(nsImage: FileIcon.image(for: entry)).resizable().frame(width: 56, height: 56)
        }
    }

    private func shown(_ image: NSImage, inset: CGFloat) -> some View {
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(inset)
    }

    var body: some View {
        // the caption is hidden to accessibility, as part of the card: VoiceOver hears the version in the label
        let otherVersion = other.flatMap { Snapshot.date(fromID: $0.snapshotID) }.map { WhenText.version($0, locale: locale) }
        return VStack(alignment: .leading, spacing: 4) {
            card
            if let otherVersion {
                Text(otherVersion).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Anteprima di \(entry.name)" + (otherVersion.map { ", " + $0 } ?? ""))
        .task(id: entry.hash) { await load() } // the content tells one version from another
    }

    /// A card that arrives late must not replace a newer selection: the task is cancelled when the file changes, and nothing is shown once it is.
    private func load() async {
        content = nil
        guard entry.kind == .file, entry.size <= Self.limit, let url = await model.previewCopy(entry), !Task.isCancelled else { return }
        // the reads stay off the main thread: only what was read comes back
        let read = await Task.detached(priority: .userInitiated) { PreviewLoader.read(url, name: entry.name) }.value
        if Task.isCancelled { return }
        switch read {
        case .image(let data):
            if let image = NSImage(data: data) { content = .image(image) }
        case .text(let text):
            content = .text(text)
        case .thumbnail:
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 520, height: 300), scale: 2, representationTypes: [.thumbnail])
            if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request), !Task.isCancelled {
                content = .thumbnail(representation.nsImage)
            }
        case nil:
            break
        }
    }
}

private enum PreviewLoader {
    /// What was read off the main thread.
    enum Read: Sendable { case image(Data), text(String), thumbnail }

    /// An image, the first lines of a text, or a thumbnail for Quick Look to make.
    nonisolated static func read(_ url: URL, name: String) -> Read? {
        let type = UTType(filenameExtension: (name as NSString).pathExtension)
        if let type, type.conforms(to: .image) { return (try? Data(contentsOf: url)).map(Read.image) }
        if isText(type, at: url) { return firstLines(of: url).map(Read.text) }
        return .thumbnail
    }

    /// Text and code by their type; a file macOS knows nothing about is text if its first bytes read as UTF-8.
    nonisolated static func isText(_ type: UTType?, at url: URL) -> Bool {
        guard let type else { return looksLikeText(head(url)) }
        if type.conforms(to: .text) { return true }
        return type.isDynamic && looksLikeText(head(url))
    }

    nonisolated static func looksLikeText(_ head: Data?) -> Bool {
        guard let head else { return false }
        return !head.contains(0) && text(head) != nil
    }

    /// The text, or nil when it is not UTF-8; a character cut in half by the end is dropped first.
    nonisolated static func text(_ data: Data) -> String? {
        var data = data
        for _ in 0..<4 {
            if let text = String(data: data, encoding: .utf8) { return text }
            guard !data.isEmpty else { return nil }
            data.removeLast()
        }
        return nil
    }

    nonisolated static func head(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: 4096)
    }

    /// The first 64 KB at most, cut at the end of a line so that no character is left half.
    nonisolated static func firstLines(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.alwaysMapped]) else { return nil }
        var bytes = data.prefix(65_536)
        if data.count > 65_536, let last = bytes.lastIndex(of: 0x0A) { bytes = bytes.prefix(last + 1) }
        guard let text = text(bytes) else { return nil }
        // a line ends with «\n», «\r\n» or «\r»: a Windows file shows its lines, not one cut line
        return text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).prefix(40).map { String($0.prefix(160)) }.joined(separator: "\n")
    }
}
```

- [ ] **Step 3: Compilare.**

Run: `swift build --product BackupMe`
Expected: `Build complete!`

- [ ] **Step 4: I test restano verdi.**

Run: `swift test 2>&1 | tail -3`
Expected: `Test run with 365 tests in 35 suites passed`

- [ ] **Step 5: Commit**

```bash
git add Sources/BackupMe/RestoreInspector.swift Sources/BackupMe/RestoreModel.swift
git commit -m "feat(app): l'ispettore di Sfoglia con la carta d'anteprima"
```

---

### Task 7: La vista `RestoreActionBar`

**Files:**
- Create: `Sources/BackupMe/RestoreActionBar.swift`

**Interfaces — Consumes:** `RestorePlanner.Bar` (Task 3), `FileIcon` (Task 5), `GlassGroup`, `glassPanel`, `glassButton` (`Glass.swift`).

**Interfaces — Produces:**

```swift
struct RestoreActionBar: View {
    static let height: CGFloat = 76           // room the list and the inspector leave for it
    let bar: RestorePlanner.Bar
    let entry: Entry?
    let disabled: Bool
    let busy: String?                         // "Ripristino in corso…", "Controllo della cartella attuale…"
    let help: String
    let revealTitle: String; let revealIcon: String
    let canReveal: Bool; let canShowVersions: Bool
    let preview: () -> Void; let compare: () -> Void
    let restore: () -> Void; let restoreInto: () -> Void
    let reveal: () -> Void; let showVersions: () -> Void
}
```

- [ ] **Step 1: Creare** `Sources/BackupMe/RestoreActionBar.swift`:

```swift
import BackupCore
import RestoreRules
import SwiftUI

/// One place for the actions, floating under the list and the inspector.
struct RestoreActionBar: View {
    /// Room the list and the inspector leave for it.
    static let height: CGFloat = 76

    let bar: RestorePlanner.Bar
    /// The file or folder the bar speaks of, for its icon.
    let entry: Entry?
    /// Off while nothing can be restored, a restore runs, or the check before «Sostituisci» runs.
    let disabled: Bool
    /// «Ripristino in corso…» or «Controllo della cartella attuale…»: the bar says it, and restores nothing while it lasts.
    let busy: String?
    let help: String
    /// In a search the Finder's place is taken by the backup that holds the result.
    let revealTitle: String
    let revealIcon: String
    let canReveal: Bool
    let canShowVersions: Bool
    let preview: () -> Void
    let compare: () -> Void
    let restore: () -> Void
    let restoreInto: () -> Void
    let reveal: () -> Void
    let showVersions: () -> Void

    var body: some View {
        GlassGroup(spacing: 8) {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 1) {
                    Text(busy ?? bar.name).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    Text(bar.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .opacity(busy == nil ? 1 : 0) // kept: the bar must not change height
                        .accessibilityHidden(busy != nil)
                }
                Spacer(minLength: 12)
                ForEach(bar.buttons, id: \.self) { button in control(button) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .glassPanel(in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder private var icon: some View {
        switch bar.icon {
        case .none: EmptyView()
        case .file, .folder:
            // the slot stays also without an entry (the folder being viewed): the text must not jump between selections
            if let entry { Image(nsImage: FileIcon.image(for: entry)).resizable().frame(width: 28, height: 28) }
            else { Color.clear.frame(width: 28, height: 28) }
        case .stack: Image(systemName: "square.stack.3d.up").font(.system(size: 22)).foregroundStyle(.secondary)
        case .drive: Image(systemName: "externaldrive").font(.system(size: 22)).foregroundStyle(.secondary)
        }
    }

    /// The restore controls are off when the window says so, and on their own while the bar is busy: a busy bar restores nothing.
    private var restoreOff: Bool { disabled || busy != nil }

    /// The menu's shortcuts are not set here: a closed Menu doesn't fire them, so the window keeps them.
    @ViewBuilder private func control(_ button: RestorePlanner.Bar.Button) -> some View {
        switch button {
        case .preview:
            Button("Anteprima", systemImage: "eye", action: preview)
                .help("La versione salvata, in Quick Look")
                .glassButton()
        case .compare:
            Button("Confronta con oggi", systemImage: "arrow.left.arrow.right", action: compare)
                .help("La versione salvata e quella di oggi, una accanto all'altra")
                .glassButton()
        case .reveal:
            Button(revealTitle, systemImage: revealIcon, action: reveal)
                .disabled(!canReveal)
                .glassButton()
        case .restore:
            Menu {
                Button("Ripristina in…", action: restoreInto)
                Divider()
                Button(revealTitle, action: reveal).disabled(!canReveal)
                Button("Mostra versioni del file", action: showVersions).disabled(!canShowVersions)
            } label: {
                Label("Ripristina", systemImage: "arrow.uturn.backward")
            } primaryAction: {
                restore()
            }
            .disabled(restoreOff)
            .help(help)
            .glassButton(prominent: true)
        case .restoreAll:
            Button("Ripristina tutto…", systemImage: "arrow.uturn.backward", action: restore)
                .disabled(restoreOff)
                .help(help)
                .glassButton(prominent: true)
        }
    }
}
```

- [ ] **Step 2: Compilare.**

Run: `swift build --product BackupMe`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/BackupMe/RestoreActionBar.swift
git commit -m "feat(app): la barra delle azioni di Sfoglia"
```

---

### Task 8: La finestra nuova

Sostituisce `RestoreView.swift` e collega tutto. Da qui in avanti la finestra è quella nuova.

**Files:**
- Modify: `Sources/BackupMe/Glass.swift`
- Modify: `Sources/BackupMe/BackupMeApp.swift`
- Replace: `Sources/BackupMe/RestoreActionBar.swift` (quattro correzioni piccole)
- Replace: `Sources/BackupMe/RestoreView.swift`

**Interfaces — Consumes:** `RestoreTimeline` (Task 4), `RestoreBrowser`, `RestoreActions`, `FileIcon` (Task 5), `RestoreInspector`, `RestoreModel.previewCopy` (Task 6), `RestoreActionBar` (Task 7), `BackupTimeline`, `WhenText`, `RestorePlanner` (Task 1–3).

- [ ] **Step 1: Il commento di `Glass.swift`.** La riga 3 dice che il vetro è solo per il pannello del menu. Sostituirla con:

```swift
// Glass is for the menu bar panel and the Sfoglia bar; the rest of the windows, and the sheets, use system chrome.
```

- [ ] **Step 2: `BackupMeApp.swift`, la misura della finestra.**

Old:
```swift
        .defaultSize(width: 1000, height: 640)
```
New:
```swift
        .defaultSize(width: 1100, height: 700)
```

- [ ] **Step 3: `BackupMeApp.swift`, colore e simbolo di stato condivisi.** Oggi sono privati di `MenuContent`; la linea del tempo li ripete. Cancellare da `MenuContent` queste due proprietà:

```swift
    private var statusColor: Color {
        switch model.status {
        case .idle: model.settings.paused || !model.settings.isConfigured ? .gray : model.hasWarnings ? .orange : .green
        case .running: .accentColor
        case .failed: .red
        }
    }

    private var statusSymbol: String {
        switch model.status {
        case .failed: "exclamationmark"
        case .running: "arrow.triangle.2.circlepath"
        case .idle: !model.settings.isConfigured ? "gearshape" : model.settings.paused ? "pause.fill"
            : model.hasWarnings ? "exclamationmark.triangle" : "checkmark"
        }
    }
```

Nello stesso file, dentro `MenuContent`, correggere i due usi:

Old:
```swift
                    Circle().fill(statusColor.gradient)
```
New:
```swift
                    Circle().fill(model.statusColor.gradient)
```

Old:
```swift
                        Image(systemName: statusSymbol).font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
```
New:
```swift
                        Image(systemName: model.statusSymbol).font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
```

E aggiungerle, non più private, in fondo a `extension AppModel` (subito dopo la chiusura di `var statusText`, prima della `}` che chiude l'estensione):

```swift

    /// The panel's status, in color and symbol, wherever it is repeated (the Sfoglia timeline too).
    var statusColor: Color {
        switch status {
        case .idle: settings.paused || !settings.isConfigured ? .gray : hasWarnings ? .orange : .green
        case .running: .accentColor
        case .failed: .red
        }
    }

    var statusSymbol: String {
        switch status {
        case .failed: "exclamationmark"
        case .running: "arrow.triangle.2.circlepath"
        case .idle: !settings.isConfigured ? "gearshape" : settings.paused ? "pause.fill"
            : hasWarnings ? "exclamationmark.triangle" : "checkmark"
        }
    }
```

- [ ] **Step 4: La barra delle azioni,** quattro correzioni piccole emesse alla revisione del Task 7: ripristina niente anche quando è occupata, tiene lo spazio dell'icona anche senza un file da mostrare, non fa leggere a VoiceOver la riga nascosta, e non ripete un `disabled`. Sostituire tutto `Sources/BackupMe/RestoreActionBar.swift` con:


```swift
import BackupCore
import RestoreRules
import SwiftUI

/// One place for the actions, floating under the list and the inspector.
struct RestoreActionBar: View {
    /// Room the list and the inspector leave for it.
    static let height: CGFloat = 76

    let bar: RestorePlanner.Bar
    /// The file or folder the bar speaks of, for its icon.
    let entry: Entry?
    /// Off while nothing can be restored, a restore runs, or the check before «Sostituisci» runs.
    let disabled: Bool
    /// «Ripristino in corso…» or «Controllo della cartella attuale…»: the bar says it, and restores nothing while it lasts.
    let busy: String?
    let help: String
    /// In a search the Finder's place is taken by the backup that holds the result.
    let revealTitle: String
    let revealIcon: String
    let canReveal: Bool
    let canShowVersions: Bool
    let preview: () -> Void
    let compare: () -> Void
    let restore: () -> Void
    let restoreInto: () -> Void
    let reveal: () -> Void
    let showVersions: () -> Void

    var body: some View {
        GlassGroup(spacing: 8) {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 1) {
                    Text(busy ?? bar.name).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    Text(bar.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .opacity(busy == nil ? 1 : 0) // kept: the bar must not change height
                        .accessibilityHidden(busy != nil)
                }
                Spacer(minLength: 12)
                ForEach(bar.buttons, id: \.self) { button in control(button) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .glassPanel(in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder private var icon: some View {
        switch bar.icon {
        case .none: EmptyView()
        case .file, .folder:
            // the slot stays also without an entry (the folder being viewed): the text must not jump between selections
            if let entry { Image(nsImage: FileIcon.image(for: entry)).resizable().frame(width: 28, height: 28) }
            else { Color.clear.frame(width: 28, height: 28) }
        case .stack: Image(systemName: "square.stack.3d.up").font(.system(size: 22)).foregroundStyle(.secondary)
        case .drive: Image(systemName: "externaldrive").font(.system(size: 22)).foregroundStyle(.secondary)
        }
    }

    /// The restore controls are off when the window says so, and on their own while the bar is busy: a busy bar restores nothing.
    private var restoreOff: Bool { disabled || busy != nil }

    /// The menu's shortcuts are not set here: a closed Menu doesn't fire them, so the window keeps them.
    @ViewBuilder private func control(_ button: RestorePlanner.Bar.Button) -> some View {
        switch button {
        case .preview:
            Button("Anteprima", systemImage: "eye", action: preview)
                .help("La versione salvata, in Quick Look")
                .glassButton()
        case .compare:
            Button("Confronta con oggi", systemImage: "arrow.left.arrow.right", action: compare)
                .help("La versione salvata e quella di oggi, una accanto all'altra")
                .glassButton()
        case .reveal:
            Button(revealTitle, systemImage: revealIcon, action: reveal)
                .disabled(!canReveal)
                .glassButton()
        case .restore:
            Menu {
                Button("Ripristina in…", action: restoreInto)
                Divider()
                Button(revealTitle, action: reveal).disabled(!canReveal)
                Button("Mostra versioni del file", action: showVersions).disabled(!canShowVersions)
            } label: {
                Label("Ripristina", systemImage: "arrow.uturn.backward")
            } primaryAction: {
                restore()
            }
            .disabled(restoreOff)
            .help(help)
            .glassButton(prominent: true)
        case .restoreAll:
            Button("Ripristina tutto…", systemImage: "arrow.uturn.backward", action: restore)
                .disabled(restoreOff)
                .help(help)
                .glassButton(prominent: true)
        }
    }
}
```

- [ ] **Step 5: Sostituire** tutto `Sources/BackupMe/RestoreView.swift` con:

```swift
import AppKit
import BackupCore
import QuickLook
import RestoreRules
import SwiftUI
import UniformTypeIdentifiers

struct RestoreView: View {
    @State var model: RestoreModel
    @State private var selectedIDs = Set<Entry.ID>()
    @State private var hit: SearchHit?
    @State private var check: Restorer.ReplaceCheck?
    /// The check of what Sostituisci would send to the Trash is running: it walks the whole folder.
    @State private var checking = false
    /// The right-hand panel: details and saved versions of the selected item.
    @AppStorage("restoreInspector") private var showInspector = true
    @State private var previewURL: URL?
    /// Bumped on every preview request: a slow extraction finishing late must not replace a newer preview.
    @State private var previewToken = 0
    /// What the "whole folder" dialog acts on, fixed when it opens: selecting something else meanwhile must not
    /// redirect Sostituisci.
    @State private var whole: (snapshotID: String, target: Target)?
    @State private var bigPreview: Entry?
    @State private var filter = ChangeFilter.all
    @State private var deletedOnly = false
    @State private var sortOrder: [KeyPathComparator<Entry>] = []
    /// Finder-style Back / Forward (⌘[ ⌘]) over the folders visited in this window.
    @State private var back: [Place] = []
    @State private var forward: [Place] = []
    @State private var columns = TableColumnCustomization<Entry>()
    /// The saved version chosen in the inspector: what the bar's Anteprima, Confronta and Ripristina act on.
    @State private var picked: SearchHit?
    /// Bumped to scroll the timeline to the chosen backup when the choice comes from outside it.
    @State private var reveal = 0
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// The sidebar's width, read from inside it: the bar starts where the sidebar ends.
    @State private var sidebarWidth: CGFloat = 0

    // split in small parts: as one chain the body is too big for the type checker
    var body: some View {
        withDialogs(withReactions(window
            .searchable(text: $model.search, prompt: "Cerca in tutti i backup")
            .searchScopes($deletedOnly) {
                Text("Tutti").tag(false)
                if model.showsStatus { Text("Solo eliminati").tag(true) }
            }))
            .quickLookPreview($previewURL)
    }

    private func withReactions(_ v: some View) -> some View {
        v.onChange(of: model.selectedID) { _, _ in selectedIDs = []; picked = nil }
            .onChange(of: model.search) { _, _ in hit = nil; picked = nil }
            // a filter hiding selected rows deselects them: actions act only on what is visible
            .onChange(of: rows.map(\.id)) { _, ids in selectedIDs.formIntersection(ids) }
            .onChange(of: deletedOnly) { _, _ in if let h = hit, !shownResults.contains(h) { hit = nil } }
            // a new selection has no chosen version yet
            .onChange(of: selectedIDs) { _, _ in picked = nil }
            .onChange(of: hit) { _, _ in picked = nil }
            .onChange(of: model.computer, initial: true) {
                hit = nil; selectedIDs = []; back = []; forward = []; picked = nil; reveal += 1
                columns[visibility: "stato"] = model.showsStatus ? .automatic : .hidden
                if !model.showsStatus { filter = .all; deletedOnly = false }
            }
            // a sidebar that hides stops reporting its width: the bar must not keep room for it
            .onChange(of: columnVisibility) { _, v in if v == .detailOnly { sidebarWidth = 0 } }
            .onChange(of: model.app.settings.destination) { _, _ in model.reload() }
            .task(id: [model.selectedID, model.source, model.currentPath, model.selected?.id, model.pendingSelection,
                       String(model.statusEpoch)]) {
                if let p = model.pendingSelection, model.children().contains(where: { $0.id == p }) {
                    selectedIDs = [p]
                    model.pendingSelection = nil
                }
                await model.refreshStatus()
            }
            .onAppear { model.reload() }
            // after every backup, and when coming back to the app: the list may have changed meanwhile
            .onChange(of: model.app.lastReport?.date) { _, _ in model.refreshList() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshList() }
            .onVolumeChange { model.refreshList() } // a destination disk plugged in or pulled out
            .background {
                Group {
                    Button("Cartella superiore", action: goUp).keyboardShortcut(.upArrow, modifiers: .command)
                        .disabled(model.source == nil || !model.search.isEmpty)
                    // the timeline takes no keyboard focus: newer and older backup from the keyboard
                    Button("Backup più recente") { stepBackup(-1) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
                    Button("Backup più vecchio") { stepBackup(1) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
                    // here, not on the bar's menu: a Menu's shortcuts don't fire while it is closed
                    Button("Ripristina") { restoreTargets() }.keyboardShortcut("r").disabled(restoreDisabled)
                    Button("Ripristina in…") { restoreTargetsInto() }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(restoreDisabled)
                }
                .opacity(0)
                .accessibilityHidden(true)
            }
    }

    private func withDialogs(_ v: some View) -> some View {
        v.confirmationDialog(Text("Ripristinare l'intera cartella «\(((whole?.target.source ?? "") as NSString).lastPathComponent)»?"),
                             isPresented: Binding(get: { whole != nil }, set: { if !$0 { whole = nil } }), presenting: whole) { w in
            let item = [(source: w.target.source, path: w.target.path)]
            // replacing in place only for folders this Mac backs up now, from this Mac's own archive, and only once
            // the check of what would go to the Trash is done (a tampered or foreign manifest, another computer's
            // folder at the same path, a backup still loading: no Sostituisci)
            if check != nil, model.app.settings.sources.contains(w.target.source) {
                Button("Sostituisci", role: .destructive) { model.restore(snapshotID: w.snapshotID, items: item, mode: .replace) }
            }
            Button("Ripristina accanto") { model.restore(snapshotID: w.snapshotID, items: item, mode: .besideOriginal) }
            Button("Ripristina in…") { chooseFolder { model.restore(snapshotID: w.snapshotID, items: item, mode: .into($0)) } }
            Button("Annulla", role: .cancel) {}
        } message: { _ in
            Text(replaceMessage)
        }
        .confirmationDialog("Aprire l'anteprima di un file grande?",
                            isPresented: Binding(get: { bigPreview != nil }, set: { if !$0 { bigPreview = nil } })) {
            Button("Apri anteprima") { if let e = bigPreview { bigPreview = nil; preview(e, confirmed: true) } }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Per mostrarlo va estratto dall'archivio in una cartella temporanea (\(ByteCountFormatter.string(fromByteCount: bigPreview?.size ?? 0, countStyle: .file))); se l'archivio è in una cartella cloud può dover essere scaricato.")
        }
        .alert(model.error?.title ?? "", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") {}
        } message: { Text(model.error?.message ?? "") }
    }

    private var window: some View {
        // backups in the timeline on the left, where they are always visible; details and versions in the inspector
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            detail
                // minimums on the columns, not on the window: a window-wide minimum makes the sidebar jump when it
                // collapses, as the window is re-constrained on every frame of the animation
                .frame(minWidth: 440, minHeight: 420)
                .safeAreaPadding(.bottom, showsBar ? RestoreActionBar.height : 0)
                .inspector(isPresented: $showInspector) {
                    inspector.inspectorColumnWidth(min: 260, ideal: 310, max: 380)
                }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbarItems }
        .hidingToolbarTitle() // the path in the toolbar says where you are; the title stays for the Window menu
        // the bar floats over the list and the inspector alike, so it is laid over the whole split view
        .overlay(alignment: .bottom) {
            if showsBar {
                let urls = todayURLs
                RestoreActionBar(
                    bar: bar, entry: barEntry, disabled: restoreDisabled, busy: busy, help: restoreHelp,
                    revealTitle: revealTitle, revealIcon: revealIcon, canReveal: !urls.isEmpty,
                    canShowVersions: barFile != nil, preview: barPreview,
                    compare: { if let e = barFile { model.compare(picked?.entry ?? e) } },
                    restore: restoreTargets, restoreInto: restoreTargetsInto, reveal: revealSelection,
                    showVersions: { showInspector = true })
                    .padding(.leading, sidebarWidth + 12)
                    .padding(.trailing, 12)
                    .padding(.bottom, 10)
            }
        }
    }

    private var sidebar: some View {
        RestoreTimeline(
            model: model, items: timelineItems, reveal: reveal, showStatus: model.showsStatus,
            statusText: model.app.statusText, statusColor: model.app.statusColor, statusSymbol: model.app.statusSymbol,
            locale: .current
        ) { id in
            model.search = "" // a backup picked while searching: show it
            model.selectedID = id
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 300)
        .background {
            GeometryReader { g in
                Color.clear.onChange(of: g.size.width, initial: true) { _, width in sidebarWidth = width }
            }
        }
    }

    private var detail: some View {
        Group {
            if !model.hasDestination {
                ContentUnavailableView {
                    Label("Nessuna destinazione", systemImage: "externaldrive.badge.xmark")
                } description: {
                    Text("Scegli dove salvare i backup per poterli sfogliare e ripristinare.")
                } actions: {
                    SettingsLink { Text("Apri Impostazioni…") }
                }
            } else if let text = model.notConnectedText {
                ContentUnavailableView(text, systemImage: "externaldrive.badge.xmark",
                                       description: Text("Collegala per sfogliare e ripristinare i backup."))
            } else {
                RestoreBrowser(
                    model: model, items: timelineItems, rows: rows, results: shownResults, actions: actions,
                    filter: $filter, deletedOnly: $deletedOnly,
                    selectedIDs: $selectedIDs, hit: $hit, showInspector: $showInspector, sortOrder: $sortOrder, columns: $columns,
                    locale: .current)
            }
        }
    }

    private var inspector: some View {
        RestoreInspector(model: model, selection: selection, status: statusOf, showsStatus: model.showsStatus,
                         picked: $picked, locale: .current)
            .safeAreaPadding(.bottom, showsBar ? RestoreActionBar.height : 0)
    }

    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Indietro", systemImage: "chevron.left", action: goBack)
                .keyboardShortcut("[").disabled(back.isEmpty || !model.search.isEmpty).help("Indietro")
            Button("Avanti", systemImage: "chevron.right", action: goForward)
                .keyboardShortcut("]").disabled(forward.isEmpty || !model.search.isEmpty).help("Avanti")
        }
        if model.search.isEmpty, model.selected != nil {
            ToolbarItem(placement: .navigation) { breadcrumb }
        }
        if model.computers.count > 1 {
            ToolbarItem(placement: .navigation) {
                Picker("Computer", selection: $model.computer) { ForEach(model.computers, id: \.self) { Text($0) } }
                    .pickerStyle(.menu)
                    .help("Computer di origine")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button(showInspector ? "Nascondi dettagli" : "Mostra dettagli", systemImage: "sidebar.trailing") { showInspector.toggle() }
                .help(showInspector ? "Nascondi dettagli e versioni" : "Mostra dettagli e versioni")
        }
    }

    // MARK: the bar

    private var timelineItems: [TimelineItem] {
        BackupTimeline.items(snapshots: model.snapshots, history: model.app.history) { model.warningCount($0) }
    }

    /// What the window has selected, for the rules: they say what «Ripristina» acts on, as they always did.
    private var selection: RestorePlanner.Selection {
        var s = RestorePlanner.Selection()
        s.backup = model.selected.map { .init(id: $0.id, date: $0.date) }
        s.searching = !model.search.isEmpty
        s.hit = hit.map { h in
            .init(backup: .init(id: h.snapshotID, date: Snapshot.date(fromID: h.snapshotID) ?? model.selected?.date ?? .distantPast),
                 entry: h.entry)
        }
        s.source = model.source
        s.path = model.currentPath
        s.visible = model.search.isEmpty ? rows : []
        s.selectedIDs = selectedIDs
        if let e = chosenFile, let picked, picked.entry.source == e.source, picked.entry.path == e.path {
            s.version = .init(backup: .init(id: picked.snapshotID, date: Snapshot.date(fromID: picked.snapshotID) ?? e.mtime),
                              entry: picked.entry)
        }
        s.sources = model.sources
        return s
    }

    private var plan: RestorePlanner.Plan { RestorePlanner.resolve(selection) }
    private var bar: RestorePlanner.Bar { RestorePlanner.bar(plan, selection: selection, compare: canCompare) }

    /// The rows chosen in the list, whatever they are.
    private var selectedRows: [Entry] { selection.visible.filter { selectedIDs.contains($0.restoreID) } }

    /// The only selected file, when there is just one: the one that has saved versions.
    private var chosenFile: Entry? {
        if !model.search.isEmpty { return hit.flatMap { $0.entry.kind == .file ? $0.entry : nil } }
        let files = model.children().filter { selectedIDs.contains($0.id) && $0.kind == .file }
        return files.count == 1 ? files.first : nil
    }

    /// The file the bar acts on: the chosen version when there is one, else the selected file.
    private var barFile: Entry? {
        if case .version(let item) = plan.action { return item.entry }
        return chosenFile
    }

    /// Confronta is for a saved file that differs from today's, on this Mac.
    private var canCompare: Bool {
        guard model.showsStatus, let e = barFile, e.kind == .file, e.hash != nil else { return false }
        return Restorer.status(of: e) == .modified
    }

    /// The file or folder the bar speaks of, for its icon.
    private var barEntry: Entry? { plan.items.count == 1 ? plan.items.first?.entry : nil }

    /// Nothing comes back from the plan, a restore runs, or the check before «Sostituisci» runs.
    private var restoreDisabled: Bool { plan.action == .nothing || model.restoring || checking }

    private var busy: String? {
        if model.restoring { return "Ripristino in corso…" }
        if checking { return "Controllo della cartella attuale…" }
        return nil
    }

    /// Hidden until there is a backup to act on, so that it doesn't flash while a backup loads.
    private var showsBar: Bool {
        model.hasDestination && model.notConnectedText == nil && (model.isLoading || !model.snapshots.isEmpty)
    }

    private var restoreHelp: String {
        // short names, big targets: what each one does exactly is in the tooltip
        switch plan.action {
        case .nothing: return "Seleziona un elemento da ripristinare"
        case .wholeBackup: return "Ripristina tutte le cartelle di questo backup in una cartella a scelta"
        case .wholeFolder: return "Ripristina «\(bar.name)»: chiede come, accanto all'originale, in una cartella… o sostituendo quella attuale"
        case .version: return "Ripristina la versione scelta accanto all'originale, senza sovrascrivere"
        case .items(let items):
            return items.count > 1 ? "Ripristina \(items.count) elementi accanto agli originali, senza sovrascrivere"
                : "Ripristina «\(bar.name)» accanto all'originale, senza sovrascrivere"
        }
    }

    /// In a search the Finder's place is taken by the backup that holds the result.
    private var revealTitle: String { model.search.isEmpty ? "Mostra nel Finder" : "Mostra nel backup" }
    private var revealIcon: String { model.search.isEmpty ? "folder" : "clock.arrow.circlepath" }

    /// What the action restores and is still on this Mac, to show in the Finder; with nothing to restore, the rows chosen.
    private var todayURLs: [URL] {
        guard model.search.isEmpty else { return hit.map { [$0.entry.url] } ?? [] }
        // «Nuovo» rows have nothing to restore: where they are today is the only thing there is to show
        let items = plan.action == .nothing ? selectedRows.map { RestorePlanner.Item($0) } : plan.items
        return items.compactMap { item in
            // the folder's rows were compared with the disk once, off the main thread; a chosen version wasn't, and there is one
            if let e = item.entry, e.kind != .directory {
                let missing = model.status(of: e).map { $0.own == .missing } ?? (Restorer.status(of: e) == .missing)
                if missing { return nil }
            }
            guard let e = item.entry else {
                // the folder being viewed
                let url = URL(fileURLWithPath: item.source).appending(path: item.path)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
            return e.url
        }
    }

    private func statusOf(_ e: Entry) -> RowStatus? {
        // the inspector shows the selection: a search result is against the disk, by its own backup
        model.search.isEmpty ? model.status(of: e)
            : model.resultStatus[SearchHit(snapshotID: hit?.snapshotID ?? "", entry: e)].map { RowStatus(own: $0) }
    }

    private var actions: RestoreActions {
        RestoreActions(
            enter: enter,
            preview: preview,
            restore: { id, items in model.restore(snapshotID: id, items: items, mode: .besideOriginal) },
            restoreInto: { id, items in chooseFolder { dir in model.restore(snapshotID: id, items: items, mode: .into(dir)) } },
            compare: { model.compare($0) },
            reveal: { h in model.reveal(h); reveal += 1 },
            quickLook: quickLook,
            dragProvider: dragProvider)
    }

    // MARK: path

    /// Every level is clickable; deep paths fold the middle levels into a "…" menu.
    private var breadcrumb: some View {
        HStack(spacing: 2) {
            crumb("Tutte le cartelle", icon: "externaldrive", current: model.source == nil) { go(Place(source: nil, path: "")) }
            if let source = model.source {
                let parts = model.currentPath.split(separator: "/").map(String.init)
                let folded = max(0, parts.count - 2)
                separator
                crumb((source as NSString).lastPathComponent, icon: "folder", current: parts.isEmpty) { open("") }
                if folded > 0 {
                    separator
                    Menu("…") {
                        ForEach(Array((0..<folded).reversed()), id: \.self) { i in
                            Button(parts[i], systemImage: "folder") { open(parts[...i].joined(separator: "/")) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                ForEach(Array(folded..<parts.count), id: \.self) { i in
                    separator
                    crumb(parts[i], icon: nil, current: i == parts.count - 1) { open(parts[...i].joined(separator: "/")) }
                }
            }
        }
        .padding(.horizontal, 6)
    }

    private var separator: some View {
        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary).accessibilityHidden(true)
    }

    private func crumb(_ name: String, icon: String?, current: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label { Text(name).lineLimit(1).truncationMode(.middle) } icon: { if let icon { Image(systemName: icon) } }
                .fontWeight(current ? .semibold : .regular)
                .foregroundStyle(current ? .primary : .secondary)
        }
        .buttonStyle(.borderless)
        .disabled(current)
    }

    /// No sort chosen keeps the index order: folders first, then names. The filter needs the folder's status.
    private var rows: [Entry] {
        var list = model.children()
        switch filter {
        case .all: break
        case .modified, .missing: list = list.filter { model.matches($0, filter) }
        case .added: list = model.added()
        }
        return sortOrder.isEmpty ? list : list.sorted(using: sortOrder)
    }

    private var shownResults: [SearchHit] {
        deletedOnly ? model.results.filter { model.resultStatus[$0] == .missing } : model.results
    }

    struct Place: Equatable { var source: String?; var path: String }

    private var here: Place { Place(source: model.source, path: model.currentPath) }

    private func open(_ path: String) { go(Place(source: model.source, path: path)) }

    /// -1 newer, +1 older, in the timeline's order.
    private func stepBackup(_ by: Int) {
        guard let i = model.snapshots.firstIndex(where: { $0.id == model.selectedID }),
              model.snapshots.indices.contains(i + by) else { return }
        model.search = ""
        model.selectedID = model.snapshots[i + by].id
        reveal += 1
    }

    private func goUp() {
        if model.currentPath.isEmpty { go(Place(source: nil, path: "")) } else { open((model.currentPath as NSString).deletingLastPathComponent) }
    }

    /// Works at the top level too, where the rows are the saved folders.
    private func enter(_ e: Entry) { go(Place(source: e.source, path: e.path)) }

    private func go(_ place: Place) {
        guard place != here else { return }
        back.append(here)
        forward = []
        show(place)
    }

    private func show(_ place: Place) {
        model.source = place.source
        model.currentPath = place.path
        model.pendingSelection = nil
        model.fixLocation() // Back / Forward may lead to a folder this backup doesn't have
        selectedIDs = []
    }

    private func goBack() {
        guard let place = back.popLast() else { return }
        forward.append(here)
        show(place)
    }

    private func goForward() {
        guard let place = forward.popLast() else { return }
        back.append(here)
        show(place)
    }

    /// Dragging a file out restores a copy where it's dropped, named so it never replaces the original.
    private func dragProvider(_ e: Entry) -> NSItemProvider? {
        guard e.kind == .file, e.hash != nil, model.search.isEmpty else { return nil }
        let provider = NSItemProvider()
        let model = model
        let type = UTType(filenameExtension: (e.name as NSString).pathExtension) ?? .data
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { done in
            Task { @MainActor in
                if let url = await model.dragCopy(e) { done(url, false, nil) } else { done(nil, false, CocoaError(.fileReadUnknown)) }
            }
            return nil
        }
        return provider
    }

    private var rootName: String { model.source.map { ($0 as NSString).lastPathComponent } ?? "Tutte le cartelle" }

    private var title: String {
        guard model.search.isEmpty else { return "Ricerca" }
        return model.currentPath.isEmpty ? rootName : (model.currentPath as NSString).lastPathComponent
    }

    private var subtitle: String {
        if model.restoring { return "Ripristino in corso…" }
        if let busy = model.busy { return busy }
        if !model.search.isEmpty {
            let n = shownResults.count
            return (n == 1 ? "1 risultato" : "\(n) risultati") + (model.resultsTruncated ? " (i primi 500)" : "")
        }
        // the path is in the path bar: here the backup being viewed
        return model.selected.map { "Backup del " + $0.date.formatted(date: .complete, time: .shortened) } ?? ""
    }

    // MARK: actions

    private typealias Target = (source: String, path: String, entry: Entry?)

    /// ⌘R, and the bar's button: what the plan says, beside the original, by the rules that always held (a whole saved folder asks first).
    private func restoreTargets() {
        guard !restoreDisabled, let id = plan.from?.id else { return }
        switch plan.action {
        case .nothing: break
        case .wholeBackup: restoreAllInto()
        case .wholeFolder(let source): askWholeFolder(source: source, id: id)
        case .items(let items):
            model.restore(snapshotID: id, items: items.map { ($0.source, $0.path) }, mode: .besideOriginal)
        case .version(let item):
            model.restore(snapshotID: id, items: [(item.source, item.path)], mode: .besideOriginal)
        }
    }

    /// ⇧⌘R, and «Ripristina in…» in the bar's menu: the same items, into a folder of choice.
    private func restoreTargetsInto() {
        guard !restoreDisabled, let id = plan.from?.id else { return }
        switch plan.action {
        case .nothing: break
        case .wholeBackup: restoreAllInto()
        case .wholeFolder, .items, .version:
            let items = plan.items.map { ($0.source, $0.path) }
            // fixed before the panel: a backup finishing while it is open may refresh the list and change the selection
            chooseFolder { dir in model.restore(snapshotID: id, items: items, mode: .into(dir)) }
        }
    }

    /// Anteprima in the bar: the chosen version, or the file as this backup has it.
    private func barPreview() {
        guard let e = barFile else { return }
        preview(picked?.entry ?? e)
    }

    /// «Mostra nel Finder», or «Mostra nel backup» in a search.
    private func revealSelection() {
        if let h = hit, !model.search.isEmpty {
            model.reveal(h)
            reveal += 1
        } else {
            let urls = todayURLs
            if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        }
    }

    /// Space in the list: Quick Look of the selected file, or close it.
    private func quickLook() -> Bool {
        guard let e = chosenFile else { return false }
        if previewURL != nil { previewURL = nil } else { preview(e) }
        return true
    }

    /// A whole saved folder asks first: replacing it is on offer there, and only there.
    private func askWholeFolder(source: String, id: String) {
        check = nil
        checking = true // a double click would start a second check, and ask twice
        Task {
            if model.showsStatus, model.app.settings.sources.contains(source) { check = await model.replaceCheck(source: source) }
            checking = false
            whole = (id, (source, "", nil))
        }
    }

    private var replaceMessage: String {
        var text = "Sostituisci sposta nel Cestino la cartella attuale, comprese le cartelle escluse dal backup (es. node_modules), e la rimpiazza con la versione salvata."
        if let check {
            if check.changedFiles > 0 {
                text += "\n\n\(check.changedFiles == 1 ? "1 file è cambiato" : "\(check.changedFiles) file sono cambiati") dopo il backup: le versioni di oggi finiranno nel Cestino."
            }
            if check.newFiles > 0 {
                text += "\n\n\(check.newFiles == 1 ? "1 file non è" : "\(check.newFiles) file non sono") nel backup (nuovi o non salvati): \(check.newFiles == 1 ? "finirà" : "finiranno") nel Cestino."
            }
            if check.repositoryChanged {
                text += "\n\nIl repository git ha commit o branch più recenti del backup: finiranno nel Cestino con la cartella."
            }
        }
        return text
    }

    /// Every saved folder this backup has: at the top level the rows are their roots. Folders with the same name
    /// go into a subfolder named after their parent ("Lavoro/src", "Personale/src"), not "src" and "src 2".
    private func restoreAllInto() {
        guard let id = model.selectedID else { return }
        let present = model.children().map(\.source)
        let missing = model.sources.filter { !present.contains($0) }
        let names = present.map { ($0 as NSString).lastPathComponent }
        var subfolders: [String: String] = [:]
        for s in present where names.filter({ $0 == (s as NSString).lastPathComponent }).count > 1 {
            subfolders[s] = ((s as NSString).deletingLastPathComponent as NSString).lastPathComponent
        }
        // a partial backup lists a folder it couldn't read: say so before a folder is chosen, not after
        if !missing.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Non tutto è in questo backup"
            alert.informativeText = "Non sono in questo backup, che è parziale: "
                + missing.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")
                + ". Per riaverle scegli un backup precedente."
            alert.addButton(withTitle: "Ripristina il resto…")
            alert.addButton(withTitle: "Annulla")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        chooseFolder { dir in
            model.restore(snapshotID: id, items: present.map { (source: $0, path: "") }, mode: .into(dir), subfolders: subfolders)
        }
    }

    private func chooseFolder(_ then: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Ripristina qui"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        then(dir)
    }

    private func preview(_ e: Entry) { preview(e, confirmed: false) }

    private func preview(_ e: Entry, confirmed: Bool) {
        if !confirmed, e.size > 200_000_000 { bigPreview = e; return }
        previewToken += 1
        let token = previewToken
        Task {
            let url = await model.extracted(e)
            if token == previewToken { previewURL = url }
        }
    }
}

extension View {
    @ViewBuilder fileprivate func hidingToolbarTitle() -> some View {
        if #available(macOS 15, *) { toolbar(removing: .title) } else { self }
    }
}

extension Entry: Identifiable {
    public var id: String { restoreID }
}
```

Cosa cambia, per chi rivede:

- Lo stato in più: `picked` (la versione scelta), `reveal` (lo scorrimento della linea del tempo), `columnVisibility` e `sidebarWidth` (per far partire la barra dove finisce la barra laterale).
- `Entry.id` (Identifiable) ora è `restoreID` di `RestoreRules`: l'espressione che distingue una riga sta in un posto solo.
- `matches` (una riga contro un filtro) sta nel modello dal Task 5: la usano la lista e la finestra, senza due copie.
- `selection`, `plan`, `bar` vengono da `RestoreRules`; `restoreTargets` e `restoreTargetsInto` seguono `plan.action`. Sono le stesse decisioni della vecchia `targets`: le prova `RestorePlannerTests`.
- `askWholeFolder(source:id:)` è il vecchio ramo della cartella salvata per intera: `check`, `checking` e il dialogo non cambiano.
- Vanno via: la barra laterale coi chip, `backupInfo`, la barra dei filtri, `actionBar`, l'ispettore vecchio con `StatusPill`, `selectionSummary`, `targets`, `wholeBackup`, `singleFile`.
- Le scorciatoie restano dove erano, nei pulsanti nascosti di `withReactions`: un `Menu` chiuso non fa scattare le sue.

- [ ] **Step 6: Compilare.**

Run: `swift build --product BackupMe`
Expected: `Build complete!`

- [ ] **Step 7: L'intera suite.**

Run: `swift test 2>&1 | tail -3`
Expected: `Test run with 365 tests in 35 suites passed`

- [ ] **Step 8: Compilare l'app come si installa** (universale: prova anche che il codice compila per Intel).

Run: `scripts/build-app.sh`
Expected: `Built build/BackupMe.app` (senza `--install`: non tocca l'app in esecuzione).

- [ ] **Step 9: Commit**

```bash
git add Sources/BackupMe/RestoreView.swift Sources/BackupMe/RestoreActionBar.swift Sources/BackupMe/BackupMeApp.swift Sources/BackupMe/Glass.swift
git commit -m "feat(app): Sfoglia backup con la finestra nuova"
```

---

### Task 9: Documenti e la sentinella dei cicli

**Files:**
- Create: `scripts/check-view-cycles.py`
- Create: `scripts/check-view-cycles-test.py`
- Modify: `README.md`
- Create: `docs/prova-sfoglia-backup.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Creare la sentinella** `scripts/check-view-cycles.py`. Cerca i cicli tra le proprietà calcolate di un tipo: due che si leggono l'una con l'altra mandano la finestra in crash al primo disegno, e né il compilatore né i test lo vedono. Vede ogni proprietà calcolata, in qualunque forma sia dichiarata, e la tiene nel suo tipo (anche tra un file e l'altro); non vede un ciclo che passa da una funzione, e lo dice nel suo commento iniziale. Creare il file con:

```python
#!/usr/bin/env python3
"""Finds cycles among the computed properties of a type: two that read each other recurse until the stack is over,
and a view that does it crashes at its first render. The compiler cannot see them and the views have no tests here,
so this is the only guard before the app runs.

Usage: check-view-cycles.py file.swift ...   (every file of the module: an extension may live in another one)
Prints each cycle found (the first 100: a last line says when there are more) and exits 1; prints nothing and exits 0
when there is none; exits 2 on a usage error.
check-view-cycles-test.py, next to it, proves all of this: run it after changing this file.

What counts as a property: every `var name: Type { … }`, whatever its attributes and modifiers, wherever its brace
is. A property belongs to the type it is declared in, and an extension is part of its type, in this file or in
another one; a type declared private, or nested in one, is known only inside its own file. What counts as a read:
the name in a body as a free identifier or after `self.` or `Self.`, outside comments, strings and regex literals
(the code inside a string interpolation counts: it runs).

What it does not see: a cycle that passes through a function. What it can get wrong: a local variable or a closure
parameter with a property's name reads as that property, which can report a cycle that is not there.
"""
import re
import sys

IDENT = r'[A-Za-z_][A-Za-z0-9_]*'
QUALIFIED = IDENT + r'(?:\.' + IDENT + r')*'
START = r'(?:^|[\n;{}])[ \t]*'
ATTRIBUTES = r'(?:(?:@[\w.]+(?:\((?:[^()]|\([^()]*\))*\))?)\s*)*'
TYPE = re.compile(START + ATTRIBUTES + r'((?:[A-Za-z_]+\s+)*)(struct|class|actor|enum|protocol|extension)\s+'
                  r'(?!(?:var|func|let)\b)(' + QUALIFIED + r')')
PROPERTY = re.compile(START + ATTRIBUTES + r'(?:' + IDENT + r'(?:\([^)\n]*\))?\s+)*?var\s+(' + IDENT + r')\s*:\s*'
                      r'[^{=\n]*?(?:\n[ \t]*)?\{')
OBSERVER = re.compile(r'\s*(?:willSet|didSet)\b')
HIDDEN = re.compile(r'\b(?:private|fileprivate)\b')
WORD = re.compile(IDENT)
MEMBER = re.compile(r'\.\s*$')
SELF = re.compile(r'\b(?:self|Self)\s*\??\s*\.\s*$')
REGEX_BEFORE = re.compile(r'(?:[=,(\[{:&|?;]|\b(?:return|case|else|try|await|throw|if|guard|in|while|where))\s*$')
BUDGET = 200_000
MAX_LISTED = 100


def blanked(src):
    """The source with comments, strings and regex literals turned into spaces: braces and names inside them are not
    code. The code inside a string interpolation stays, it runs like any other; a string inside it is skipped too."""
    out = list(src)
    i, n, stack = 0, len(src), []

    def space(start, stop):
        for k in range(start, min(stop, n)):
            if out[k] != '\n': out[k] = ' '

    while i < n:
        if stack and stack[-1][0] == 'string':
            _, closer, opening, hashes = stack[-1]
            if src.startswith(opening, i):
                # the interpolation's opening is not code; what is inside is, up to its closing parenthesis
                space(i, i + len(opening))
                i += len(opening)
                stack.append(['interpolation', 1])
            elif src[i] == '\\':
                k = i + 1
                for _ in range(hashes):
                    if k < n and src[k] == '#': k += 1
                space(i, k + 1)
                i = k + 1
            elif src.startswith(closer, i):
                space(i, i + len(closer))
                i += len(closer)
                stack.pop()
            else:
                space(i, i + 1)
                i += 1
        elif stack and src[i] == '(' and stack[-1][0] == 'interpolation':
            stack[-1][1] += 1
            i += 1
        elif stack and src[i] == ')' and stack[-1][0] == 'interpolation':
            stack[-1][1] -= 1
            if not stack[-1][1]: space(i, i + 1); stack.pop()
            i += 1
        else:
            # code, at top level or inside an interpolation
            j = i
            while src[j:j + 1] == '#': j += 1
            hashes = j - i
            if src.startswith('//', j):
                end = src.find('\n', j)
                space(i, n if end < 0 else end)
                i = n if end < 0 else end
            elif src.startswith('/*', j):
                depth, k = 1, j + 2
                while k < n and depth:
                    if src.startswith('/*', k): depth, k = depth + 1, k + 2
                    elif src.startswith('*/', k): depth, k = depth - 1, k + 2
                    else: k += 1
                space(i, k)
                i = k
            elif src.startswith('"""', j) or src[j:j + 1] == '"':
                quotes = src[i:j + 3] if src.startswith('"""', j) else src[i:j + 1]
                space(i, i + len(quotes))
                i += len(quotes)
                stack.append(['string', quotes[hashes:] + '#' * hashes, '\\' + '#' * hashes + '(', hashes])
            elif src[j:j + 1] == '/' and REGEX_BEFORE.search(src[:i]):
                # a regex literal can hold quotes and braces: it ends at the slash its escapes do not protect
                k = j + 1
                while k < n and not src.startswith('/' + '#' * hashes, k):
                    if src[k] == '\\':
                        k += 1
                        for _ in range(hashes):
                            if k < n and src[k] == '#': k += 1
                    k += 1
                space(i, min(k + 1 + hashes, n))
                i = min(k + 1 + hashes, n)
            else:
                i += 1
    return ''.join(out)


def closing(clean, opening):
    """Where the brace opened at `opening` closes; the end of the text if it never does."""
    depth, i = 1, opening + 1
    while i < len(clean) and depth:
        depth += (clean[i] == '{') - (clean[i] == '}')
        i += 1
    return i - 1


def declarations(clean):
    """Each type declaration of a file, in order: (start, name, hidden, end, extended). `name` is qualified
    (`Outer.Inner`), `hidden` says that only the file can see the type, `extended` is the type an extension
    extends, None for a type."""
    raw = []
    for m in TYPE.finditer(clean):
        brace = clean.find('{', m.end())
        raw.append((m.start(), m.group(2), m.group(3), HIDDEN.search(m.group(1)) is not None,
                    closing(clean, brace) if brace >= 0 else -1))
    hidden, found = {}, []
    for _ in range(2):
        # twice: a type nested in an extension and an extension of it learn of each other in the second pass
        stack, found = [], []
        for start, kind, simple, private, end in raw:
            while stack and stack[-1][2] <= start: stack.pop()
            if kind == 'extension':
                # the extension's own modifiers say who sees its members; they hide a type nested in it, not its type
                own = private or hidden.get(simple, False)
                found.append((start, simple, own, end, simple))
                stack.append((simple, own, end))
            else:
                name = stack[-1][0] + '.' + simple if stack else simple
                own = private or (bool(stack) and stack[-1][1])
                found.append((start, name, own, end, None))
                hidden[name] = own
                stack.append((name, own, end))
    return found


def scopes(path, decls):
    """For each declaration: the key its properties are known under. A type only its own file can see gets the file."""
    local = {name for _, name, hidden, _, extended in decls if extended is None and hidden}
    keys = []
    for _, name, hidden, _, extended in decls:
        if extended is None: keys.append((path, name) if hidden else name)
        else: keys.append((path, extended) if extended in local else extended)
    return keys


def properties(path, src):
    """The computed properties of a file: the key of their type, their name, their line, their body."""
    clean = blanked(src)
    decls = declarations(clean)
    keys = scopes(path, decls)
    found = []
    for m in PROPERTY.finditer(clean):
        opening = m.end() - 1
        end = closing(clean, opening)
        body = clean[opening + 1:end]
        # a stored property has braces too, for its observers, and reading it in its own didSet is no recursion
        if OBSERVER.match(body): continue
        owners = [k for k, d in zip(keys, decls) if d[0] <= m.start() and end <= d[3]]
        found.append((owners[-1] if owners else (path, ''), m.group(1), src.count('\n', 0, m.start(1)) + 1, body))
    return found


def components(count, edges):
    """The sets of properties that reach each other: a cycle can only run inside one of them."""
    seen, order = set(), []
    for i in range(count):
        if i in seen: continue
        seen.add(i)
        stack = [(i, iter(sorted(edges[i])))]
        while stack:
            node, following = stack[-1]
            j = next(following, None)
            if j is None:
                order.append(node)
                stack.pop()
            elif j not in seen:
                seen.add(j)
                stack.append((j, iter(sorted(edges[j]))))
    back = {}
    for i in range(count):
        for j in edges[i]: back.setdefault(j, []).append(i)
    seen, found = set(), []
    for i in reversed(order):
        if i in seen: continue
        seen.add(i)
        group, stack = [], [i]
        while stack:
            node = stack.pop()
            group.append(node)
            for j in back.get(node, []):
                if j not in seen: seen.add(j); stack.append(j)
        if len(group) > 1 or group[0] in edges[group[0]]: found.append(group)
    return found


def cycles_in(files):
    """Each cycle once, at most MAX_LISTED: the file and the line of its first property, and the names that form it,
    back to the first. A last entry without names says that the list stopped early."""
    nodes, by_name = [], {}
    for path, src in files:
        for scope, name, line, body in properties(path, src):
            by_name.setdefault((scope, name), []).append(len(nodes))
            nodes.append((path, scope, name, line, body))
    edges = []
    for _, scope, _, _, body in nodes:
        reads = set()
        for word in WORD.finditer(body):
            # a member access is somebody else's, unless it goes through `self`
            if MEMBER.search(body, 0, word.start()) and not SELF.search(body, 0, word.start()): continue
            reads.add(word.group())
        edges.append({j for read in reads for j in by_name.get((scope, read), [])})
    found, left = [], [BUDGET]

    def walk(members, start, node, path):
        # a cycle is listed from its first property, so each comes out once
        for j in sorted(edges[node]):
            if left[0] < 0 or len(found) >= MAX_LISTED: return
            left[0] -= 1
            if j == start: found.append(path)
            elif j in members and j > start and j not in path: walk(members, start, j, path + [j])

    for group in components(len(nodes), edges):
        for start in sorted(group): walk(set(group), start, start, [start])
    cycles = []
    for loop in found:
        path, _, _, line, _ = nodes[loop[0]]
        names = []
        for j in loop:
            type = owner(nodes[j][1])
            names.append(type + '.' + nodes[j][2] if type else nodes[j][2])
        cycles.append((path, line, names + [names[0]]))
    cycles.sort(key=lambda c: (c[0], c[1], c[2]))
    if found and (left[0] < 0 or len(found) >= MAX_LISTED): cycles.append((nodes[0][0], None, []))
    return cycles


def owner(scope):
    """The type's name, whether it is one every file can see or one that stays in its own file."""
    return scope[1] if isinstance(scope, tuple) else scope


def main(paths):
    if not paths:
        print("usage: check-view-cycles.py file.swift ...", file=sys.stderr)
        return 2
    files = []
    for path in paths:
        try:
            with open(path, encoding="utf-8") as f:
                files.append((path, f.read()))
        except OSError as error:
            print(error, file=sys.stderr)
            return 2
    found = cycles_in(files)
    for path, line, names in found:
        print(f"{path}:{line}: " + " → ".join(names) if names else f"{path}: more cycles exist: the list stops here")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

- [ ] **Step 2: Creare il suo test** `scripts/check-view-cycles-test.py`. La prima versione della sentinella prometteva di non perdersi nessun ciclo e invece taceva davanti a casi veri (due proprietà con lo stesso nome in un file, una dichiarazione con `static`, una graffa a capo): ogni forma che deve vedere ha un caso qui, accanto al codice che deve lasciare in pace.

```python
#!/usr/bin/env python3
"""Proves check-view-cycles.py: the cycles it has to find and the code it has to leave alone. Run it after changing
the sentinel:

python3 scripts/check-view-cycles-test.py
"""
import os
import subprocess
import sys
import tempfile
import textwrap
import time

SENTINEL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "check-view-cycles.py")

# (what the case is about, its files, the cycles expected: for each, the properties that form it)
CYCLE = ["S.a S.b"]
CASES = [
    ("two properties that read each other", {"S.swift": "struct S {\n    var a: Int { b }\n    var b: Int { a }\n}\n"}, CYCLE),
    ("a property that reads itself", {"S.swift": "struct S {\n    var a: Int { self.a }\n}\n"}, ["S.a"]),
    ("a stored property with an observer is not one", {"S.swift": "struct S {\n    var a: String? { didSet { load(a) } }\n}\n"}, []),
    ("the same name in two types: only the one that cycles", {"S.swift": """
        struct A { var x: Int { y }; var y: Int { x } }
        struct B { var x: Int { 1 }; var y: Int { x } }
    """}, ["A.x A.y"]),
    ("a view with three properties and a later view with one of their names", {"S.swift": """
        struct W {
            var plan: Int { selection }
            var selection: Int { barFile }
            var barFile: Int? { plan }
        }
        struct OtherView { var selection: Int { 5 } }
    """}, ["W.plan W.selection W.barFile"]),
    ("a member access is not a read", {"S.swift": r'''
        struct V {
            var body: some View { Text("x").font(.body.monospaced()) }
            var text: String { body }
        }
    '''}, []),
    ("a brace inside a string", {"S.swift": r'''
        struct S {
            var a: Int {
                let s = "}"
                return b
            }
            var b: Int { a }
        }
    '''}, CYCLE),
    ("a name inside a comment or a string is not a read", {"S.swift": r'''
        struct S {
            var a: Int { b }
            var b: Int { 1 } // a
            var c: String { "a" }
        }
    '''}, []),
    ("static properties", {"S.swift": """
        enum E {
            static var a: Int { b }
            static var b: Int { a }
        }
    """}, ["E.a E.b"]),
    ("a read through `Self.`", {"S.swift": """
        enum E {
            static var a: Int { Self.b }
            static var b: Int { Self.a }
        }
    """}, ["E.a E.b"]),
    ("any attributes and modifiers", {"S.swift": """
        struct T {
            @ViewBuilder
            @MainActor public private(set) nonisolated var a: some View { b }
            private var b: some View { a }
        }
    """}, ["T.a T.b"]),
    ("an attribute written on several lines", {"S.swift": r'''
        struct A {
            @Attribute(
                key: "value {"
            )
            var a: Int { b }
            var b: Int { a }
        }
    '''}, ["A.a A.b"]),
    ("a brace on the next line", {"S.swift": """
        struct G
        {
            var a: Int { b }
            var b: Int
            {
                a
            }
        }
    """}, ["G.a G.b"]),
    ("an extension is part of its type", {"S.swift": """
        struct H { var a: Int { b } }
        extension H { var b: Int { a } }
    """}, ["H.a H.b"]),
    ("an extension in another file", {"H.swift": "struct H { var a: Int { b } }\n",
                                      "H+More.swift": "extension H { var b: Int { a } }\n"}, ["H.a H.b"]),
    ("a `private extension` does not hide the type", {"S.swift": """
        struct S { var a: Int { b } }
        private extension S { var b: Int { a } }
        struct U { var a: Int { b } }
        fileprivate extension U { var b: Int { a } }
    """}, ["S.a S.b", "U.a U.b"]),
    ("an extension of a private type of the same file", {"S.swift": """
        private struct Row { var a: Int { b } }
        extension Row { var b: Int { a } }
    """}, ["Row.a Row.b"]),
    ("a `package` type extended in another file", {"S.swift": "package struct S { var a: Int { b } }\n",
                                                   "S+More.swift": "extension S { var b: Int { a } }\n"}, ["S.a S.b"]),
    ("an extension of a nested type", {"S.swift": """
        struct Outer {
            struct Inner { var a: Int { b } }
        }
        extension Outer.Inner { var b: Int { a } }
    """}, ["Outer.Inner.a Outer.Inner.b"]),
    ("a type nested in an extension, extended again", {"S.swift": """
        struct Outer { }
        extension Outer {
            struct Inner { var a: Int { b } }
        }
        extension Outer.Inner { var b: Int { a } }
    """}, ["Outer.Inner.a Outer.Inner.b"]),
    ("two unrelated types with the same names", {"S.swift": """
        struct P { var a: Int { b } }
        struct Q { var b: Int { 1 } }
    """}, []),
    ("two private types with the same name in two files are not one", {"P.swift": "private struct Row { var a: Int { b } }\n",
                                                                       "Q.swift": "private struct Row { var b: Int { a } }\n"}, []),
    ("nested types with the same name under two types are not one", {"S.swift": """
        struct P { struct Inner { var x: Int { y }; var y: Int { 1 } } }
        struct Q { struct Inner { var y: Int { x }; var x: Int { 5 } } }
    """}, []),
    ("types with the same name nested in two extensions are not one", {"S.swift": """
        struct P { }
        struct Q { }
        extension P { struct Inner { var x: Int { y }; var y: Int { 1 } } }
        extension Q { struct Inner { var y: Int { x }; var x: Int { 5 } } }
    """}, []),
    ("private nested types with the same name in two files are not one",
     {"P.swift": "private struct Outer { struct Inner { var x: Int { y }; var y: Int { 1 } } }\n",
      "Q.swift": "private struct Outer { struct Inner { var y: Int { x }; var x: Int { 5 } } }\n"}, []),
    ("types with the same name in two private extensions in two files are not one",
     {"P.swift": "struct P { }\nprivate extension P { struct Helper { var x: Int { y }; var y: Int { 1 } } }\n",
      "Q.swift": "struct Q { }\nprivate extension Q { struct Helper { var y: Int { x }; var x: Int { 5 } } }\n"}, []),
    ("a read inside a string interpolation", {"S.swift": r'''
        struct J {
            var title: String { "\(count)" }
            var count: Int { title.count }
        }
    '''}, ["J.title J.count"]),
    ("a string inside an interpolation, holding a brace", {"S.swift": r'''
        struct N {
            var a: Int {
                let s = "\(wrap("{"))"
                return s.count + b
            }
            var b: Int { a }
        }
    '''}, ["N.a N.b"]),
    ("a raw string", {"S.swift": r'''
        struct R {
            var a: Int {
                let s = #"a "b" { }"#
                return b
            }
            var b: Int { a }
        }
    '''}, ["R.a R.b"]),
    ("a regex literal", {"S.swift": r'''
        struct X {
            var a: Int {
                let r = /"|{/
                return b
            }
            var b: Int { a }
        }
    '''}, ["X.a X.b"]),
    ("a regex literal after `return`, holding a brace", {"S.swift": r'''
        struct X {
            var a: Int {
                let s = "x"
                return /^}$/.wholeMatch(in: s) == nil ? 0 : b
            }
            var b: Int { a }
        }
    '''}, ["X.a X.b"]),
    ("a regex literal after `where`, holding a brace", {"S.swift": r'''
        struct X {
            var a: Int {
                var n = 0
                for s in ["x", "y"] where /^}$/.wholeMatch(in: s) != nil { n += 1 }
                return n > 0 ? 0 : b
            }
            var b: Int { a }
        }
    '''}, ["X.a X.b"]),
    ("an extended regex literal", {"S.swift": r'''
        struct X {
            var a: Int {
                let ok = #/^}$/#.wholeMatch(in: "x") == nil
                return ok ? 0 : b
            }
            var b: Int { a }
        }
    '''}, ["X.a X.b"]),
    ("a regex literal on several lines", {"S.swift": r'''
        struct X {
            var a: Int {
                let r = /^
                    }|{
                    $/
                return (r.wholeMatch(in: "x") == nil) ? 0 : b
            }
            var b: Int { a }
        }
    '''}, ["X.a X.b"]),
    ("a division after a force unwrap is not a regex literal", {"S.swift": r'''
        struct D {
            var a: Int {
                let d = [1: 2]
                let x = d[1]! / 2
                return x + b
            }
            var b: Int { a }
        }
    '''}, ["D.a D.b"]),
    ("cycles that share properties, each one listed", {"S.swift": """
        struct S {
            var a: Int { flag ? b : c }
            var b: Int { a }
            var c: Int { b }
            var flag: Bool { true }
        }
    """}, ["S.a S.b", "S.a S.b S.c"]),
    ("a nested type is its own", {"S.swift": """
        struct Outer {
            var a: Int { inner }
            var inner: Inner { Inner() }
            struct Inner {
                var x: Int { y }
                var y: Int { x }
            }
        }
    """}, ["Outer.Inner.x Outer.Inner.y"]),
    ("a stored property is not read as one", {"S.swift": "struct S {\n    var a: Int = 0\n    var b: Int { a }\n}\n"}, []),
]

# (what the case is about, the files, the exit code expected, the seconds it may take): the exit code alone is checked
DENSE = [
    ("a type dense with reads and no cycle is fast", False, 0),
    ("a type dense with reads and one cycle is answered in bounded time", True, 1),
]


def dense(count, back):
    """A type whose every property reads all the later ones; with `back`, the last one reads the first."""
    rows = ["    var p%d: Int { %s }" % (i, " ".join("p%d" % j for j in range(i + 1, count)) or "0") for i in range(count)]
    if back: rows[-1] = "    var p%d: Int { p0 }" % (count - 1)
    return {"D.swift": "struct D {\n" + "\n".join(rows) + "\n}\n"}


def check(files):
    """(exit code, seconds, for each cycle: its line and the properties that form it)"""
    with tempfile.TemporaryDirectory() as folder:
        paths = []
        for name, src in files.items():
            paths.append(os.path.join(folder, name))
            with open(paths[-1], "w", encoding="utf-8") as f:
                f.write(textwrap.dedent(src).lstrip("\n"))
        started = time.time()
        out = subprocess.run([sys.executable, SENTINEL] + paths, capture_output=True, text=True)
        cycles = []
        for line in out.stdout.splitlines():
            where, names = line.rsplit(": ", 1)
            cycles.append((int(where.rsplit(":", 1)[1]) if where.rsplit(":", 1)[-1].isdigit() else None,
                           sorted(set(names.split(" → ")))))
        return out.returncode, time.time() - started, cycles


def main():
    failed, passed = 0, 0

    def ok(label, good, found):
        nonlocal failed, passed
        if good: passed += 1; print(f"ok   {label}")
        else: failed += 1; print(f"NO   {label}: {found}")

    for label, files, expected in CASES:
        code, _, cycles = check(files)
        ok(label, code == (1 if expected else 0) and [names for _, names in cycles] == [sorted(name.split()) for name in expected],
           f"expected {expected}, found {cycles} (exit {code})")
    for label, back, expected in DENSE:
        code, seconds, cycles = check(dense(40, back))
        ok(label, code == expected and seconds < 10 and (not back or cycles[-1][0] is None),
           f"expected exit {expected} in under 10 s, found exit {code} in {seconds:.1f} s with {len(cycles)} lines")
    line = check(CASES[0][1])[2][0][0]
    ok("the line of the first property", line == 2, f"expected 2, found {line}")
    code = subprocess.run([sys.executable, SENTINEL], capture_output=True).returncode
    ok("no file to check: exit 2", code == 2, f"expected exit 2, found exit {code}")
    print(f"{passed} of {passed + failed} cases passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 3: Renderle eseguibili.**

Run: `chmod +x scripts/check-view-cycles.py scripts/check-view-cycles-test.py`

- [ ] **Step 4: Provarla.**

Run: `python3 scripts/check-view-cycles-test.py; echo "exit $?"`
Expected: una riga `ok` per ogni caso, poi `42 of 42 cases passed` e `exit 0`.

Run: `python3 scripts/check-view-cycles.py Sources/BackupMe/*.swift; echo "exit $?"`
Expected: solo `exit 0` (nessuna riga prima).

Run: `printf 'struct S {\n    var a: Int { b }\n    var b: Int { c }\n    var c: Int { a }\n}\n' > /tmp/ciclo.swift && python3 scripts/check-view-cycles.py /tmp/ciclo.swift; echo "exit $?"; rm /tmp/ciclo.swift`
Expected: `/tmp/ciclo.swift:2: S.a → S.b → S.c → S.a`, poi `exit 1`.

- [ ] **Step 5: Il README,** sezione «Sviluppo», in fondo al file.

Old:

````markdown
## Sviluppo

```bash
swift test
```

Il motore (`Sources/BackupCore`) non ha interfaccia ed è coperto da test; l'app (`Sources/BackupMe`) è solo UI e pianificazione.
````

New:

````markdown
## Sviluppo

```bash
swift test
python3 scripts/check-view-cycles.py Sources/BackupMe/*.swift
```

Il motore (`Sources/BackupCore`) non ha interfaccia ed è coperto da test; l'app (`Sources/BackupMe`) è solo UI e pianificazione. Le regole dell'interfaccia che non dipendono dalle viste stanno in `Sources/RestoreRules` e sono provate come il motore. Le viste non hanno test: due proprietà calcolate che si leggono l'una con l'altra fanno andare la finestra in crash al primo disegno, e lo scopre solo il secondo comando.
````


- [ ] **Step 6: Creare la lista di prova** `docs/prova-sfoglia-backup.md`. Ogni riga dice cosa si deve vedere, senza rimandare a com'era la finestra vecchia: chi la usa non ha più quella sotto gli occhi.

```markdown
# Prova di Sfoglia backup (finestra nuova)

Da fare con un archivio vero (OneDrive o un disco esterno) dopo `scripts/build-app.sh --install`, nell'ordine. Ogni riga va segnata quando passa; una che non passa va scritta in fondo a questa lista, con cosa si è visto.

I test automatici coprono le regole (le sezioni della linea del tempo, i testi di data e ora, cosa «Ripristina» ripristina, quali righe passano i filtri): quarantadue test in `Tests/BackupCoreTests`, i cui nomi cominciano con `BackupTimelineTests`, `WhenTextTests`, `RestorePlannerTests`, `SelectionSummaryTests` e `RowFilterTests`. Quello che segue è ciò che solo a schermo si vede.

## Linea del tempo

- [ ] **Prima di tutto: la finestra si apre** e l'app resta in esecuzione (l'icona resta nella barra dei menu, un backup in corso non si interrompe). Aprirla e chiuderla tre volte di seguito.
- [ ] La finestra si apre 1100×700 con tre colonne: linea del tempo, lista, ispettore.
- [ ] Appena aperta la barra delle azioni sta già al suo posto, staccata dalla linea del tempo: non salta da sinistra verso il centro.
- [ ] L'ultima riga della lista e l'ultimo elemento dell'ispettore non stanno sotto la barra delle azioni.
- [ ] «Ripristina» spento (per esempio durante un ripristino) non apre il menu.
- [ ] Si sceglie una versione nell'ispettore, poi si nasconde l'ispettore: la barra dice ancora «versione del …» e «Ripristina» ripristina quella versione.
- [ ] In cima la carta ripete la riga di stato del pannello della barra dei menu (stesso testo, colore e simbolo); un clic porta all'ultimo backup.
- [ ] Ogni backup è una riga: un punto sulla linea verticale, l'ora, la barra e «+N MB». Un backup con avvisi ha punto e barra arancioni e il triangolo.
- [ ] Un backup che non ha salvato niente ha la barra vuota e nessun numero.
- [ ] Le sezioni sono «Oggi · …», «Ieri · …», i giorni della settimana, poi i mesi; dal più recente. Scorrendo, le intestazioni restano ferme in alto.
- [ ] A destra dell'intestazione c'è il totale dei dati del periodo («+1,2 GB») dove ci sono dati.
- [ ] I backup più vecchi delle ultime 50 esecuzioni, e quelli dell'archivio di un altro computer, non hanno barra né «+N MB»; il triangolo dell'avviso compare solo per un backup il cui indice è in memoria.
- [ ] Il suggerimento e VoiceOver leggono data completa, MB e avvisi.
- [ ] ⌥⌘↑ e ⌥⌘↓ cambiano backup e l'elenco scorre fino a mostrarlo; un clic su una riga non fa scorrere niente.
- [ ] All'apertura della finestra, e al cambio di computer, l'elenco scorre fino al backup scelto.
- [ ] Un clic sul bordo sinistro e su quello destro di una riga sceglie proprio quella riga.
- [ ] Scegliere molti backup in fretta non blocca l'app.
- [ ] Durante una ricerca, un clic su una riga chiude la ricerca e mostra quel backup.

## Titolo e filtri

- [ ] Sopra la lista: «Stai guardando il backup di», «Ieri alle 15:00», «lunedì 23 novembre 2026 · +210 MB salvati · 1 avviso» (senza dati resta la data sola).
- [ ] I tag Tutto, Modificati, Eliminati, Nuovi filtrano le righe. Finite di confrontare la cartella con oggi, «Modificati», «Eliminati» e «Nuovi» portano il numero degli elementi che lo sono, e «Tutto» quello di tutte le righe (zero: nessun numero).
- [ ] Con un filtro acceso e niente da mostrare: «Nessuna modifica», «Nessun elemento eliminato» o «Niente di nuovo». Finché il confronto non è finito: «Confronto con oggi…».
- [ ] Un filtro che nasconde una riga selezionata la deseleziona: la barra non la elenca più.
- [ ] Con l'archivio di un altro computer: niente carta, niente tag, niente colonna «Rispetto a oggi».

## Lista dei file

- [ ] Ordinamento delle colonne, colonne che si nascondono, selezione multipla.
- [ ] Doppio clic: una cartella si apre, un file va in anteprima. Spazio apre e chiude Quick Look.
- [ ] Tasto destro su una o più righe: «Apri» (una cartella), «Anteprima» (un file), «Ripristina» e «Ripristina in…»; per un file anche «Mostra versioni del file» e, se è modificato, «Confronta con la versione attuale».
- [ ] Tasto destro su un elemento «Nuovo»: solo «Mostra nel Finder».
- [ ] ⌘↑ (cartella superiore), ⌘[ e ⌘] (indietro e avanti).
- [ ] Trascinare un file nel Finder ne ripristina una copia, col nome «… (ripristinato …)».
- [ ] Le etichette sono Nuovo, Modificato, Eliminato, Contiene modifiche, Contiene eliminati.

## Ispettore

- [ ] Niente selezionato: «Nessuna selezione», con «Seleziona un file per vederne dettagli e versioni.». Più elementi: «N elementi selezionati» con il riepilogo (cartelle, file, dimensione) e «Seleziona un solo file per vederne dettagli e versioni.».
- [ ] Un elemento: icona grande, nome, etichetta dello stato; Dimensione (solo per un file: «15 KB allora · 18 KB oggi»), Modificato, Posizione.
- [ ] Un'immagine, un file di testo e un PDF mostrano il contenuto nella carta; un file sopra i 20 MB mostra l'icona.
- [ ] Un file di testo con fine riga alla Windows (un CSV esportato da Excel, un `.bat`) mostra le sue prime righe nella carta, non una riga sola.
- [ ] Scorrere con le frecce da un file all'altro: la carta non mostra per un attimo la versione scelta nel file precedente.
- [ ] Scegliere una versione la evidenzia e cambia la riga della barra in «versione del …»; la carta mostra quella versione.
- [ ] Sotto «Versioni» c'è il conto («3 salvate») e una riga per ogni contenuto diverso, dalla più recente. «Cerca le versioni in tutti i backup» legge gli altri backup non ancora letti, e l'elenco dice «Restano N backup da leggere…».
- [ ] Selezionare molti file in fretta non blocca la finestra, e una carta lenta non sostituisce una selezione più recente.
- [ ] Un file che non si può estrarre lascia l'icona, senza avvisi.

## Barra delle azioni

- [ ] Dentro una cartella, niente selezionato: il nome della cartella; «Ripristina» la ripristina accanto all'originale.
- [ ] Un file modificato da allora: Anteprima · Confronta con oggi · Ripristina ▾. Un file non modificato: Anteprima · Ripristina ▾.
- [ ] Dentro una cartella, con un file, una sottocartella o più elementi selezionati: «Ripristina» (anche con ⌘R) rimette quelli, e solo quelli, accanto all'originale, senza sovrascrivere niente.
- [ ] Una cartella salvata per intera: «Ripristina» chiede (Sostituisci, Ripristina accanto, Ripristina in…), con il conto di quello che finirebbe nel Cestino. Mentre fa il controllo la barra dice «Controllo della cartella attuale…» e i pulsanti stanno spenti.
- [ ] «Sostituisci» non compare per l'archivio di un altro computer, né per una cartella che questo Mac non salva.
- [ ] A «Tutte le cartelle», niente selezionato: «Ripristina tutto…» chiede una cartella.
- [ ] Solo elementi «Nuovi»: «Niente da ripristinare qui», e «Mostra nel Finder» al posto del pulsante: lo si preme e il Finder mostra quei file dove sono oggi.
- [ ] Più elementi: «N elementi», il riepilogo, «Ripristina ▾».
- [ ] Menu «▾»: «Ripristina in…»; «Mostra nel Finder» (spento se non c'è più niente da mostrare); «Mostra versioni del file» (solo con un file): apre l'ispettore.
- [ ] ⌘R e ⇧⌘R fanno la stessa cosa del pulsante e della voce di menu.
- [ ] Durante un ripristino la barra dice «Ripristino in corso…» e i pulsanti stanno spenti. Un ripristino alla volta, anche chiudendo e riaprendo la finestra.
- [ ] La capsula sta in fondo sotto lista e ispettore; con l'ispettore chiuso, o la barra laterale nascosta, si allarga.
- [ ] Passando da una cartella a un file, a più elementi e a «Tutte le cartelle», la capsula non cambia altezza e il testo non salta.
- [ ] Il vetro non dà glitch su macOS 26 o successivi (e, se disponibile, la capsula opaca su 14 o 15).

## Aspetto scuro

- [ ] Con l'aspetto scuro di macOS: il tag del filtro in uso, i badge di stato e la barra delle azioni si leggono (niente bianco su bianco).

## Ricerca

- [ ] Il titolo è la ricerca tra virgolette, con il conteggio dei risultati; i tag sono Tutti e Solo eliminati.
- [ ] Doppio clic su un risultato: «Mostra nel backup» chiude la ricerca, apre la cartella e seleziona il file; se il suo backup sta fuori schermo, la linea del tempo scorre fino a mostrarlo.
- [ ] Un risultato selezionato: la barra dice «dal backup di …» e «Ripristina» ripristina quel file accanto all'originale, anche se nessun backup è ancora aperto.
- [ ] Niente selezionato: la barra dice «Seleziona un risultato», con «Mostra nel backup» spento.
- [ ] Senza risultati il pannello dice che non ha trovato niente per il testo cercato. Con «Solo eliminati» senza risultati: «Nessun file eliminato».

## Stati vuoti

- [ ] Senza una destinazione: «Nessuna destinazione», con «Apri Impostazioni…». Disco non collegato: «Destinazione non collegata: …», con «Collegala per sfogliare e ripristinare i backup.».
- [ ] «Nessun backup», con «I backup di questo Mac compariranno qui dopo il primo salvataggio.», e «Scegli un backup», con «Scegline uno nella barra laterale.». In tutti questi stati la barra non si vede.
- [ ] Un disco esterno scollegato e ricollegato mentre la finestra è aperta: la finestra se ne accorge.

## Cosa non è passato

(una riga per ogni problema: cosa si è fatto, cosa si è visto)
```

- [ ] **Step 7: La voce di changelog.** In `CHANGELOG.md`, subito prima di `## [1.0.1] - 2026-11-24`, inserire questa sezione (seguita da una riga vuota):

```markdown
## [Non pubblicato]

### Cambiato
- Sfoglia backup rifatta. La barra laterale è una linea del tempo: ogni backup è un punto sulla linea, con l'ora, una barra lunga quanto i dati salvati e «+N MB»; un backup con avvisi è arancione. In cima una carta ripete lo stato del pannello della barra dei menu. Il pannello centrale dice in grande «Ieri alle 15:00», con la data, i dati salvati e gli avvisi; i filtri Modificati, Eliminati e Nuovi sono tag. L'ispettore, più largo, mostra un'anteprima del file (immagini, testo, anteprima rapida degli altri tipi, fino a 20 MB) e le versioni su una linea. Le azioni stanno in una capsula in fondo, sotto lista e ispettore: Anteprima, Confronta con oggi e un solo «Ripristina» con menu («Ripristina in…», «Mostra nel Finder», «Mostra versioni del file»). Scegliendo una versione nell'ispettore, «Ripristina» ripristina quella. Le regole non cambiano: cosa si ripristina, da quale backup e quando chiede prima lo decide il target nuovo `RestoreRules`, provato con 42 test. La finestra si apre 1100×700.
```

- [ ] **Step 8: Commit**

```bash
git add scripts/check-view-cycles.py scripts/check-view-cycles-test.py README.md docs/prova-sfoglia-backup.md CHANGELOG.md
git commit -m "docs: lista di prova della finestra nuova di Sfoglia, CHANGELOG e sentinella dei cicli nelle viste"
```
```

---

## Verifica sul Mac (dopo l'installazione)

I test automatici coprono le regole; l'aspetto e il comportamento a schermo no. Con l'archivio vero:

- [ ] `scripts/build-app.sh --install`, poi aprire **Sfoglia backup…** dal pannello della barra dei menu.
- [ ] Percorrere `docs/prova-sfoglia-backup.md` dall'inizio alla fine e segnare ogni riga.
- [ ] Se la capsula di vetro dà glitch (il difetto di 0.3.0), applicare il ripiego della spec: in `RestoreActionBar.swift` togliere `GlassGroup` e `glassPanel`, e in `RestoreView.swift` sostituire l'`overlay` della barra con una barra in fondo alla colonna centrale (`.safeAreaInset(edge: .bottom)`), poi ricontrollare le righe «Barra delle azioni» della lista.
