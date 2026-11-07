# Formato dell'archivio (formato 1)

Descrive l'archivio come lo scrive il codice della 1.0. Il codice fa testo: `Sources/BackupCore/Repository.swift` (struttura, oggetti, manifest, lock), `Models.swift` (Snapshot, Entry), `ArchiveOwner.swift` (proprietario), `BackupEngine.swift` (cosa finisce nel manifest), `RestoreKit.swift` (kit di ripristino). Il nome dell'archivio lo sceglie l'app in `Sources/BackupMe/Settings.swift` (`AppPaths.archiveName`).

## Struttura

```
<destinazione>/                    scelta dall'utente (può essere un collegamento)
  BackupMe/
    RIPRISTINO.command             kit di ripristino (0755)
    LEGGIMI.txt                    istruzioni del kit (0644)
    <archivio>/                    uno per Mac e account, permessi 0700
      repo.json                    identità e formato
      lock                         lock dei processi che scrivono
      objects/
        xx/                        xx = prime due cifre dell'hash
          <sha256>.lzfse           contenuto compresso
          <sha256>.raw             contenuto così com'è
      snapshots/
        <id>.json.lzfse            manifest di un backup
```

- **`<archivio>`**: `<nome del Mac>-<id8>-<utente>` per gli archivi nuovi, `<nome del Mac>-<id8>` per quelli creati prima che il nome contenesse l'account. `id8` sono i primi 8 caratteri dell'UUID hardware (`gethostuuid`). `Repository` sostituisce `/` e `:` con `-`. È un archivio ogni cartella sotto `BackupMe/` che contiene `repo.json` (`Repository.computers`).
- **Cartelle** create con `0755`, quella dell'archivio con `0700` (`archiveDirectory`). Nessuna cartella dell'archivio può essere un collegamento: si aprono con `O_NOFOLLOW`.
- **File temporanei**: ogni scrittura passa da `<nome>.tmp` nella stessa cartella, poi `fsync` (`F_FULLFSYNC` per i manifest) e rinomina. Un `.tmp` rimasto in `objects/` o `snapshots/` è un avanzo e la pulizia lo cancella (`removeTemporaryFiles`).

## repo.json

Scritto alla creazione come `{"format":1,"id":"<UUID>","created":<secondi>}`. Poi `claim(owner:)` lo riscrive a chiavi ordinate aggiungendo il proprietario.

| Campo | Tipo | Significato |
|---|---|---|
| `format` | intero | Versione del formato (`Repository.format`, oggi 1). Se manca vale 1. |
| `id` | stringa | UUID (`UUID().uuidString`, maiuscolo con trattini) dell'archivio. Cambia solo se l'archivio viene ricreato. |
| `created` | numero | Data di creazione, secondi dal 1970 (con decimali). |
| `owner` | intero, facoltativo | uid dell'account che scrive l'archivio. |
| `ownerName` | stringa, facoltativo | Nome breve dell'account (`NSUserName()`). |

- Un `repo.json` leggibile ma senza `id` è danneggiato: viene riscritto con un id nuovo. Se invece la lettura fallisce (un file cloud non scaricato), non viene toccato.
- Proprietario: se `owner` e `ownerName` sono entrambi diversi dall'account corrente, scrivere dà `otherOwner`. Basta che coincida uno dei due (stesso account con un uid nuovo dopo Migration Assistant). Un archivio senza `owner` va al primo account che lo rivendica, dentro `withLock`.

## ID

- **Archivio**: il campo `id` di `repo.json` (UUID).
- **Backup (snapshot)**: data UTC nel formato `yyyy-MM-dd'T'HH-mm-ss'Z'`, locale `en_US_POSIX`, per esempio `2026-11-05T10-00-00Z` (`Snapshot.id(for:)`). Se esiste già un manifest con quell'id si aggiunge un secondo: un manifest al secondo, mai sovrascritto.
  Un backup che non trova niente di cambiato e ha ancora il digest dell'ultimo manifest, se quel manifest è ancora integro, non ne scrive uno nuovo: riporta l'id di quello precedente.
- **Oggetto**: SHA-256 del contenuto originale (non compresso), 64 cifre esadecimali minuscole (`Repository.isHash`).

## Oggetti

`objects/<prime 2 cifre>/<sha256>.<ext>`. Lo stesso contenuto si salva una volta sola, qualunque sia il numero di file, cartelle e backup che lo usano.

- **`.lzfse`**: il contenuto compresso con `NSData.compressed(using: .lzfse)`. Si usa per i file sotto 32 MiB (`Repository.streamThreshold`) quando la compressione fa risparmiare più del 5% (compresso `< data.count * 95 / 100` in aritmetica intera, quindi la soglia è arrotondata per difetto).
- **`.raw`**: il contenuto byte per byte. Si usa per i file vuoti, per quelli poco comprimibili e per tutti quelli da 32 MiB in su, che vengono copiati in streaming (con un clone APFS se si può) e verificati prima della rinomina.
- In lettura si cerca prima `.lzfse`, poi `.raw`; il contenuto decompresso deve avere lo SHA-256 del nome, altrimenti `corruptObject`. Un oggetto danneggiato non viene mai cancellato in lettura.
- Permessi: `0644` per gli oggetti scritti dalla memoria (i `.lzfse` e i `.raw` sotto 32 MiB); quelli copiati in streaming tengono i permessi del file d'origine.

## Manifest

`snapshots/<id>.json.lzfse` è un JSON UTF-8 compresso con LZFSE (`NSData`). Il manifest si scrive per ultimo: un backup senza manifest non esiste e i suoi oggetti li toglie la pulizia. È immutabile: si crea con una rinomina esclusiva e non si sovrascrive mai (`writeSnapshot`).

**Codifica.** `JSONEncoder` con `.sortedKeys` e date `.secondsSince1970` (numeri, con decimali), senza spazi. I campi facoltativi a `nil` non compaiono. La `/` è scritta come `\/` (comportamento predefinito di `JSONEncoder`): il checksum copre i byte esatti del file, quindi chi lo verifica fa l'hash dei byte letti, senza ricodificare il JSON.

**Checksum.** Dal JSON codificato si toglie la `{` iniziale; il resto è il *corpo*. Il file contiene:

```
{"check":"<sha256 esadecimale del corpo>",<corpo>
```

Il checksum copre quindi tutti i byte dal 77° in poi: 10 di `{"check":"`, 64 dell'hash, 2 di `",`. Chi legge verifica che il byte 65 dopo il prefisso sia `"` e il 66 sia `,`, e che l'hash corrisponda; altrimenti `damagedSnapshot`. Un manifest senza il prefisso (scritto prima della 0.9.2) è accettato, ma basta un `hash` che non sia un hash valido per considerarlo danneggiato. Chi non conosce `check` lo ignora come una chiave qualsiasi.

**Snapshot** (`Models.swift`):

| Campo | Tipo | Significato |
|---|---|---|
| `id` | stringa | ID del backup, uguale al nome del file. |
| `date` | numero | Data del backup, secondi dal 1970. |
| `sources` | [stringa] | Percorsi assoluti degli elementi salvati (cartelle o singoli file), anche quelli che in questo backup mancano. |
| `entries` | [Entry] | Le voci salvate. |
| `warnings` | [stringa] | Errori delle sorgenti (mancanti, illeggibili, spazio esaurito) seguiti dagli avvisi. Il limite di 200 righe vale su errori e avvisi insieme; le righe in più diventano una sola, "… e un altro avviso" o "… e altri N avvisi". |

Non c'è un campo "parziale". Un backup è parziale in tre casi: una voce di `sources` non ha voci in `entries` (sorgente mancante o illeggibile), una cartella non si è potuta leggere, oppure lo spazio era esaurito e alcuni file non sono stati salvati, anche se la loro sorgente ha voci. In tutti e tre i casi il motivo è in `warnings`. Il contrario non vale: `warnings` non vuoto non vuol dire parziale, perché ci finiscono anche avvisi semplici (per esempio un file non leggibile o cambiato durante la lettura). Il kit chiama parziale solo il backup con cartelle mancanti; negli altri casi dice che il backup ha N avvisi.

**Entry**:

| Campo | Tipo | Significato |
|---|---|---|
| `source` | stringa | Percorso assoluto dell'elemento salvato a cui appartiene la voce. |
| `path` | stringa | Percorso relativo a `source`; `""` è l'elemento stesso (la cartella, o il file se l'elemento è un file singolo). |
| `kind` | `"file"` \| `"directory"` \| `"symlink"` | Tipo. Socket, FIFO e dispositivi non vengono salvati. |
| `hash` | stringa, facoltativo | Solo per `file`: SHA-256 del contenuto, cioè il nome dell'oggetto. |
| `size` | intero (Int64) | `st_size` dello `lstat`; ha senso solo per i file. |
| `mtime` | numero | Data di modifica, secondi dal 1970 come Double (precisione di circa 0,2 µs, non i nanosecondi di `stat`). |
| `mode` | intero (UInt16) | `st_mode & 0o7777`: permessi POSIX, compresi setuid, setgid e sticky. |
| `linkTarget` | stringa, facoltativo | Solo per `symlink`: destinazione del collegamento così com'è scritta. |

## Lock

`lock` è un file regolare vuoto (`0644`). Chi scrive lo apre con `O_NOFOLLOW` e prende un `flock(LOCK_EX)` per tutta l'operazione (`withLock`): backup, pulizia, rivendicazione del proprietario, verifica a campione e controllo completo (`BackupEngine.swift`, `Pruner.swift`, `Verify.swift`). Il sistema rilascia il lock quando il processo muore, e il file non viene mai cancellato. Sui filesystem senza `flock` (alcuni exFAT o SMB) si procede senza lock. Ogni Mac scrive solo il proprio archivio, quindi un lock locale basta.

## Compatibilità

- **Campi nuovi solo facoltativi.** `JSONDecoder` ignora le chiavi che non conosce, quindi una versione vecchia legge i manifest di una nuova. Un campo nuovo dev'essere facoltativo, perché una versione nuova legga i manifest vecchi che non ce l'hanno. Così sono stati aggiunti `check` nei manifest e `owner`/`ownerName` in `repo.json`.
- **Un cambio incompatibile alza `format`**: struttura delle cartelle, nomi, codifica degli oggetti o del manifest, significato di un campo esistente.
- **Formato più nuovo: si sfoglia ma non si scrive.** Se `repo.json` ha `format` maggiore di `Repository.format`, `Repository(create: true)` e `withLock` lanciano `newerFormat`. Il controllo dentro `withLock` copre ogni scrittura, anche da un archivio aperto con `create: false` ("Controlla ora", "Elimina…"). Aprire con `create: false` per sfogliare resta possibile.
- **Il kit legge `format`** (se manca vale 1) e si ferma con un errore se è maggiore del formato con cui è stato generato (`Repository.format` incorporato nello script). Il kit ha una versione propria (`RestoreKit.version`, riga `// BackupMe-kit: N` nello script), e un'app non sostituisce mai un kit di versione più alta.
