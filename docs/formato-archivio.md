# Formato dell'archivio (formato 2)

Descrive l'archivio come lo scrive il codice dopo la 1.0. Il codice fa testo: `Sources/BackupCore/Repository.swift` (struttura, oggetti, manifest, lock), `Pack.swift` e `RepositoryPacks.swift` (contenitori), `Pruner.swift` e `PackMaintenance.swift` (pulizia, compattazione, conversione), `Models.swift` (Snapshot, Entry), `ArchiveOwner.swift` (proprietario), `BackupEngine.swift` (cosa finisce nel manifest), `RestoreKit.swift` (kit di ripristino). Il nome dell'archivio lo sceglie l'app in `Sources/BackupMe/Settings.swift` (`AppPaths.archiveName`).

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
      packs/                       contenitori (solo se ce n'è almeno uno)
        <id>.pack                  tanti oggetti piccoli in un file
        <id>.idx                   indice del contenitore
      snapshots/
        <id>.json.lzfse            manifest di un backup
```

- **`<archivio>`**: `<nome del Mac>-<id8>-<utente>` per gli archivi nuovi, `<nome del Mac>-<id8>` per quelli creati prima che il nome contenesse l'account. `id8` sono i primi 8 caratteri dell'UUID hardware (`gethostuuid`). `Repository` sostituisce `/` e `:` con `-`. È un archivio ogni cartella sotto `BackupMe/` che contiene `repo.json` (`Repository.computers`).
- **Cartelle** create con `0755`, quella dell'archivio con `0700` (`archiveDirectory`). Nessuna cartella dell'archivio può essere un collegamento: si aprono con `O_NOFOLLOW`.
- **File temporanei**: ogni scrittura passa da `<nome>.tmp` nella stessa cartella, poi `fsync` (`F_FULLFSYNC` per i manifest) e rinomina. Un `.tmp` rimasto in `objects/`, `packs/` o `snapshots/` è un avanzo e la pulizia lo cancella (`removeTemporaryFiles`, `removePackLeftovers`); in `packs/` è un avanzo anche un `.idx` senza il suo `.pack`.

## repo.json

Scritto alla creazione come `{"format":1,"id":"<UUID>","created":<secondi>}`: un archivio nuovo è di formato 1 finché non ha contenitori, e `flushPack` lo porta a `"format":2` un attimo prima di pubblicare il primo (un archivio segnato 1 non ne contiene mai). Poi `claim(owner:)` lo riscrive a chiavi ordinate aggiungendo il proprietario.

| Campo | Tipo | Significato |
|---|---|---|
| `format` | intero | Versione del formato (`Repository.format`, oggi 2, il più alto che questa versione legge e scrive). Se manca vale 1. |
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
- **Contenitore**: 16 cifre esadecimali minuscole (`Repository.isPackID`), il nome comune di `packs/<id>.pack` e `packs/<id>.idx`. Vedi *Contenitori*.

## Oggetti

Un oggetto sta in una di due forme: un file suo, `objects/<prime 2 cifre>/<sha256>.<ext>`, oppure un record in un contenitore (vedi *Contenitori*). Dove va lo decide chi scrive: l'app mette in un contenitore le forme salvate sotto 4 MiB (`Repository.packThreshold`, parametro `packBelow`), mentre senza `packBelow`, il predefinito del motore, ogni oggetto è un file suo. Chi legge deve accettare entrambe le forme, anche per lo stesso oggetto. Lo stesso contenuto si salva una volta sola, qualunque sia il numero di file, cartelle e backup che lo usano.

Quanto segue vale per le due forme: `.lzfse` e `.raw` sono i due modi di salvare il contenuto, che sia un file o un record.

- **`.lzfse`**: il contenuto compresso con `NSData.compressed(using: .lzfse)`. Si usa per i file sotto 32 MiB (`Repository.streamThreshold`) quando la compressione fa risparmiare più del 5% (compresso `< data.count * 95 / 100` in aritmetica intera, quindi la soglia è arrotondata per difetto).
- **`.raw`**: il contenuto byte per byte. Si usa per i file vuoti, per quelli poco comprimibili e per tutti quelli da 32 MiB in su, che vengono copiati in streaming (con un clone APFS se si può) e verificati prima della rinomina.
- In lettura (`readObject`) si cerca prima il file, `.lzfse` poi `.raw`; se manca o il suo contenuto non ha lo SHA-256 del nome si passa alla copia nel contenitore con l'id più alto, poi alle altre copie. Vale la prima il cui contenuto decompresso ha lo SHA-256 del nome; se nessuna lo ha, `corruptObject`. Un oggetto danneggiato non viene mai cancellato in lettura.
- Permessi: `0644` per gli oggetti scritti dalla memoria (i `.lzfse` e i `.raw` sotto 32 MiB); quelli copiati in streaming tengono i permessi del file d'origine.

## Contenitori

Un contenitore raccoglie molti oggetti piccoli in un file, perché un archivio con milioni di file minuscoli non sia milioni di file sul cloud. `packs/<id>.pack` è il contenitore, `packs/<id>.idx` il suo indice, che si può sempre ricostruire dal contenitore. Un contenitore è immutabile: si scrive per intero con una rinomina esclusiva (`flushPack`) e non si modifica più.

**`.pack`** (`Pack.swift`):

```
BMPACK1\n                         8 byte
record, uno dopo l'altro:
  hash      32 byte              lo SHA-256 dell'oggetto, i byte grezzi (non le 64 cifre)
  codifica  1 byte               0 = .raw, 1 = .lzfse
  lunghezza 4 byte               big-endian, dei byte salvati
  byte      <lunghezza>          la forma salvata, come sarebbe il file .raw o .lzfse
```

L'intestazione di un record è di 37 byte (`Pack.headerSize`); il contenitore finisce con l'ultimo record, senza altro. Il contenuto decompresso di ogni record ha lo SHA-256 del suo hash. Un file che non comincia con `BMPACK1\n`, ha un record tagliato o una codifica diversa da 0 e 1 è danneggiato (`damagedPack`).

**`.idx`** (`Pack.encodeIndex`, `Pack.decodeIndex`): un file LZFSE (`NSData`) il cui contenuto è

```
<64 cifre esadecimali dello SHA-256 del corpo>\n<corpo>
```

Il corpo è un JSON senza spazi, `[["<hash>",<offset>,<lunghezza>,<0|1>],…]`, una voce per record, in ordine di offset. `offset` è il punto del contenitore dove cominciano i byte salvati, subito dopo l'intestazione del record (quindi mai prima di 45), `lunghezza` è quella del record e l'ultimo valore la codifica. Un indice è valido se si decomprime, il checksum corrisponde, ogni voce sta dentro il contenitore e l'ultima finisce esattamente alla sua fine.

**Id.** 16 cifre esadecimali minuscole: il maggiore tra l'id più alto che c'è già più uno e i millisecondi dal 1970 (`flushPack`). Gli id sono quindi strettamente crescenti, anche con l'orologio spostato indietro.

**Più copie, vince l'id più alto.** Un oggetto può stare in più contenitori (una compattazione lo copia in uno nuovo prima di togliere il vecchio) e anche in un file suo. La copia che conta è quella del contenitore con l'id più alto; le altre servono solo se quella non si legge o non verifica (`packIndex`, `readObject`).

**Lettura.**
- L'indice si carica dai `.idx` e dalla dimensione del contenitore, mai dai suoi byte: aprire l'archivio non legge nessun contenitore, e su OneDrive con i file su richiesta leggerlo vorrebbe dire scaricarlo (`packEntries`).
- Il contenuto decide: si legge il record indicato dall'indice e si controlla il suo SHA-256. Solo se non torna si guarda l'intestazione del record e, se non coincide con l'indice, questo si ricostruisce dal contenitore (`readPacked`).
- Un indice mancante, danneggiato o che non combacia con la dimensione del contenitore si ricostruisce da questo (`Pack.scan`). Lo si riscrive solo con il lock preso: sfogliare non scrive mai.
- Una copia che non si riesce a leggere (il file non è raggiungibile) è «non letta», mai «danneggiata»: non si dichiara danneggiato quello che non si è potuto leggere.

**Scrittura.** Le forme salvate sotto `packBelow` si accumulano nel contenitore aperto, che si pubblica a circa 32 MiB (`Repository.packTarget`) e comunque prima del manifest (`writeSnapshot`): un manifest non cita mai un oggetto che non è su disco. Prima il `.pack`, poi l'`.idx`.

**Cancellazione** (`Pruner.swift`, `PackMaintenance.swift`). Un contenitore si cancella intero, e solo quando: il suo indice è integro (combacia con la dimensione); ogni contenitore che ha la copia che conta delle sue voci ancora in uso è confermato; e quelle copie sono state lette e verificate nella stessa chiamata. Prima l'`.idx`, poi il `.pack` (`deletePack`). Compattazione e conversione non cancellano mai da sole e si fermano senza rumore se qualcosa non si legge. La pulizia tiene fuori dall'archivio, in un file locale `cleanup` accanto alla cache dei riferimenti, l'elenco degli oggetti «condannati» (non usati all'ultima raccolta giornaliera): un backup nuovo non riusa mai un oggetto condannato, e prima di ogni cancellazione si tolgono dall'elenco quelli citati dai manifest più recenti. Il tetto orario alle cancellazioni è dell'app e non cambia il formato.

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
- **Formato 2 e versioni precedenti.** Una versione che conosce solo il formato 1 non scrive in un archivio di formato 2 (`newerFormat`) e non ne ripristina per intero i backup: gli oggetti dentro un contenitore, per lei, non esistono. Il kit di versione 9 si ferma subito con «Archivio di formato 2, più recente di questo script…». Il kit di versione 10 legge i formati 1 e 2. Un archivio di formato 1 resta di formato 1 finché non nasce il primo contenitore, e si legge identico con tutte le versioni.
- **Formato più nuovo: si sfoglia ma non si scrive.** Se `repo.json` ha `format` maggiore di `Repository.format`, `Repository(create: true)` e `withLock` lanciano `newerFormat`. Il controllo dentro `withLock` copre ogni scrittura, anche da un archivio aperto con `create: false` ("Controlla ora", "Elimina…"). Aprire con `create: false` per sfogliare resta possibile.
- **Il kit legge `format`** (se manca vale 1) e si ferma con un errore se è maggiore del formato con cui è stato generato (`Repository.format` incorporato nello script). Il kit ha una versione propria (`RestoreKit.version`, riga `// BackupMe-kit: N` nello script), e un'app non sostituisce mai un kit di versione più alta.
