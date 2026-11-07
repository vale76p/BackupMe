# BackupMe — modulo Backup: design

Data: 2026-11-05 · Stato: attuata (1.0). Cosa è cambiato rispetto a questo testo: [Differenze rispetto alla spec](#differenze-rispetto-alla-spec).

## Perché

Sul Mac aziendale (gestito da MDM) Time Machine è disabilitato. I progetti e il codice che non stanno su un cloud drive non hanno backup: un disco rotto o un `rm` sbagliato = lavoro perso, inclusi commit mai pushati. BackupMe è uno strumento **personale** che sostituisce Time Machine per queste cartelle, scrivendo i backup nella cartella **OneDrive aziendale** sincronizzata in locale.

## Obiettivi

- Backup di una o più cartelle verso una cartella destinazione (OneDrive sincronizzato o qualsiasi altra cartella/disco).
- Ultraleggera: app nativa Swift, nessun processo extra, nessuna dipendenza esterna.
- Gira come utente, installata in `~/Applications`, senza permessi di amministratore; si avvia al login.
- Gestita dalla barra dei menu (topbar).
- Backup pianificati + su richiesta.
- Ripristino di una cartella intera o di singoli file, sfogliando i backup nel tempo.
- Retention configurabile: tutti nelle 24h, N giornalieri, N settimanali, N mensili.
- Tetto massimo allo spazio occupato dal pool dei backup.
- Compilata in locale (computer gestito da MDM: niente distribuzione firmata/notarizzata).

## Non-obiettivi (per ora)

- **Git, rinviato a una fase successiva** (deciso con l'utente il 2026-11-06). La richiesta originale ("un cloud o un'altra cartella o git") comprende due cose, entrambe volute ma non ora:
  - git aziendale configurabile come **destinazione** dei backup;
  - **modulo grafico** stile GitHub Desktop sul git aziendale.
  Ognuna avrà un suo design. Qui nessun codice git (le cartelle `.git` dei progetti però vengono salvate).
- Cifratura dell'archivio (deciso: in chiaro).
- Login/API Microsoft: OneDrive è solo una cartella; carica il client OneDrive.
- Più destinazioni contemporanee, pianificazioni diverse per cartella.
- Attributi estesi, ACL, tag Finder, resource fork (si salvano contenuto, permessi POSIX, data di modifica, symlink).
- Deduplica a blocchi dentro il file (vedi "Formato").
- Rispettare `.gitignore` (escluderebbe proprio `.env` e simili che vogliamo salvare).

## Anti-obiettivi (sarebbe un fallimento anche se "funziona")

- Un ripristino che sovrascrive file dell'utente senza rete di sicurezza.
- Un backup interrotto (sleep, spegnimento, OneDrive che sincronizza) che lascia l'archivio corrotto o un backup "a metà" che sembra completo.
- Ventole/batteria: rileggere e ri-hashare tutti i file ogni ora.
- Richiedere password di amministratore o profili MDM.

## Vincoli

- macOS 14+ (la macchina attuale è macOS 27.2, Swift 6.4, Xcode installato).
- Mac gestito da MDM: build locale, firma ad-hoc (`codesign -s -`), app non in quarantena perché compilata sul posto.
- OneDrive non gestisce gli hard link (Time Machine li usa): l'archivio non deve basarsi su hard link.
- OneDrive "File su richiesta" può togliere i file locali e lasciarli solo nel cloud: leggerli li riscarica; nessuna operazione deve richiedere di rileggere tutto l'archivio a ogni backup.

## Decisioni prese con l'utente

- Strumento personale; destinazione principale = cartella OneDrive aziendale sincronizzata (`~/Library/CloudStorage/OneDrive-…`).
- Contenuto: cartelle di progetti/codice, **`.git` incluso**.
- Archivio **in chiaro**.
- "Max size" = **tetto massimo del pool**: superato il tetto si cancellano i backup più vecchi anche prima della scadenza.
- Ripristino: **layout B**, finestra tipo Finder (lista backup a sinistra, contenuto al centro).
- Ordine: prima il backup, poi il modulo git.

## Come funziona

### Architettura

- Un solo `BackupMe.app` SwiftUI, agent (`LSUIElement`, niente icona nel Dock), con `MenuBarExtra`.
- Avvio al login tramite `SMAppService.mainApp`. *Mia scelta; se con la firma ad-hoc non funziona, ripiego su un plist in `~/Library/LaunchAgents` scritto dall'app.*
- Il pianificatore è dentro l'app (timer + notifica di risveglio da `NSWorkspace`): nessun daemon separato.
- Il motore è una libreria Swift separata (`BackupCore`) senza UI, così è testabile; l'app è solo UI + pianificazione.
- Progetto SwiftPM + script `scripts/build-app.sh`: `swift build -c release`, assembla il bundle `.app` con `Info.plist`, firma ad-hoc, copia in `~/Applications`. *Mia scelta: nessun progetto Xcode da mantenere; se `MenuBarExtra`/notifiche richiedono un bundle Xcode vero, il builder può passare a un `.xcodeproj` generato.*
- Non sandboxata (build locale, deve leggere cartelle arbitrarie). Al primo accesso a `~/Documents` / `~/Desktop` macOS chiede il permesso: va bene.

### Formato dell'archivio (mia scelta)

Nella destinazione:

```
<destinazione>/BackupMe/<nome computer>/
  repo.json                     # versione formato, id repo, data creazione
  objects/ab/abcdef….lzfse      # contenuto file, nome = SHA-256 del contenuto originale, compresso LZFSE
  snapshots/2026-11-05T10-00-00Z.json.lzfse   # manifest di un backup
  lock                          # presente durante backup/pulizia
```

- **Deduplica per file intero**: un file identico in N backup (o in N cartelle) è salvato una volta. Un file grande modificato di poco si salva di nuovo per intero. *shortcut: per il codice (tanti file piccoli) basta; se compaiono file grandi che cambiano spesso, passare a chunking a contenuto variabile.*
- Il manifest elenca ogni voce: cartella sorgente, percorso relativo, tipo (file/cartella/symlink), hash, dimensione, data di modifica, permessi, destinazione del symlink. Indica anche avvisi (file illeggibili, file cambiati durante la lettura).
- Una cartella per computer: se un giorno lo usi su due Mac non si pestano i piedi, e da un altro Mac si possono sfogliare i backup del primo.
- Scrittura atomica: ogni oggetto si scrive in un file temporaneo e poi si rinomina; il manifest si scrive **per ultimo**. Un backup interrotto non ha manifest → non esiste; i suoi oggetti orfani li elimina la pulizia successiva.
- `lock` con PID e host: un secondo backup non parte se ce n'è uno in corso; un lock vecchio di un processo morto si rimuove.

### Backup

1. Per ogni cartella sorgente percorre l'albero, saltando gli esclusi e senza seguire i symlink.
2. Per ogni file usa una cache locale (`~/Library/Application Support/BackupMe/`) con chiave percorso+inode+dimensione+data di modifica → hash. Se non è cambiato non lo rilegge (niente ventole).
3. Se l'hash non è già in `objects/`, comprime e copia. L'esistenza si controlla con un indice locale degli oggetti noti, ricostruibile elencando `objects/` (elencare non scarica i file da OneDrive).
4. Se un file cambia mentre lo legge, riprova una volta; poi lo salta con un avviso nel manifest.
5. Scrive il manifest, poi applica retention e tetto.

**Esclusioni di default** (modificabili, pattern per nome): `node_modules`, `.build`, `DerivedData`, `build`, `dist`, `.venv`, `venv`, `__pycache__`, `.DS_Store`, `Pods`, `.gradle`, `target`. `.git` è incluso.

### Pianificazione

- Intervallo configurabile: 1, 2, 4, 6, 12, 24 ore (default 1 h).
- Se al lancio o al risveglio l'ultimo backup è più vecchio dell'intervallo, ne parte uno (con un breve ritardo dopo il risveglio, per far ripartire la rete/OneDrive).
- "Esegui backup ora" dal menu; "Sospendi backup" per mettere in pausa la pianificazione.
- Le Impostazioni rifiutano una sorgente che contiene la destinazione o sta dentro di essa (backup ricorsivo).
- Se la destinazione non esiste (OneDrive scollegato), il backup fallisce con un errore chiaro e niente file creati altrove.

### Retention

Dopo ogni backup riuscito, si tengono:
- tutti i backup delle ultime 24 ore;
- per gli ultimi **N giorni** (default 14) l'ultimo backup di ogni giorno;
- per le ultime **N settimane** (default 8) l'ultimo di ogni settimana (lunedì-domenica);
- per gli ultimi **N mesi** (default 12) l'ultimo di ogni mese;
- **sempre** il backup più recente.

Giorni, settimane e mesi si calcolano nel fuso orario locale (i nomi dei manifest restano in UTC). Gli altri manifest si cancellano; poi la pulizia (garbage collection) elimina gli oggetti non più usati da nessun manifest.

### Tetto massimo del pool

- Impostazione in GB (default: nessun tetto; *mia scelta*). Il pool è la somma delle dimensioni dei file in `objects/` più i manifest.
- Dopo la retention, se il pool supera il tetto: si cancella il backup più vecchio, si fa la pulizia e si ripete, finché si rientra o resta solo il più recente.
- Se anche il solo backup più recente supera il tetto, lo si tiene comunque e si avvisa con una notifica ("il tetto è troppo basso per le cartelle selezionate").

### Barra dei menu

Icona con lo stato (normale / in corso / errore). Il menu contiene:
- stato: "Ultimo backup: oggi 10:00" / "Backup in corso… 42%" / "Errore: destinazione non trovata"
- Esegui backup ora (oppure Interrompi, se è in corso)
- Sfoglia backup…
- Sospendi backup / Riprendi
- Impostazioni…
- Esci

Notifiche solo per gli errori e per "nessun backup riuscito da 3 giorni".

### Impostazioni

Una finestra con:
- elenco delle cartelle sorgente (+/−);
- cartella destinazione, con un suggerimento automatico se trova `~/Library/CloudStorage/OneDrive-*`;
- intervallo;
- retention (giorni, settimane, mesi);
- tetto del pool in GB;
- esclusioni, una per riga;
- avvio al login.

In fondo mostra lo spazio occupato e il numero di backup.

### Ripristino (layout B)

- Finestra "Sfoglia backup…". In alto si sceglie la cartella sorgente (e, se ci sono, i backup di altri computer).
- A sinistra i backup raggruppati in Oggi / Ieri / Settimana scorsa / Mesi precedenti.
- Al centro l'albero della cartella in quel backup, navigabile. Ogni elemento ha un'etichetta: "modificato rispetto a oggi" oppure "non più presente oggi".
- Ricerca per nome file in tutti i backup.
- "Mostra versioni del file": elenca le versioni distinte (hash diversi) nel tempo, ciascuna ripristinabile.
- **Ripristina** su file o sottocartella: crea la copia accanto all'originale, con nome `nome (ripristinato 5 nov 10.00).ext`. Non sovrascrive mai.
- **Ripristina** su cartella sorgente intera: chiede "Sostituisci" o "Ripristina in…". "Sostituisci" sposta prima la versione attuale nel Cestino.
- **Ripristina in…**: salva in una cartella scelta dall'utente.
- Il ripristino ricrea permessi, data di modifica e symlink, e verifica l'hash di ogni file scritto.
- Da un Mac nuovo si sceglie la stessa destinazione OneDrive e si sfogliano i backup del vecchio computer.

### Errori e log

- Log con `os.Logger` (visibile in Console.app); nell'app si conserva lo storico delle ultime 50 esecuzioni (data, durata, file, byte nuovi, avvisi, errore).
- Un errore su un singolo file non fa fallire il backup (diventa un avviso). Fanno fallire il backup: destinazione mancante, disco pieno, errore di scrittura del manifest.

## Test

- `BackupCore` con test unitari:
  - selezione della retention (date sintetiche);
  - giro completo backup → ripristino in cartelle temporanee, con confronto byte per byte di permessi, symlink e data di modifica;
  - deduplica (due backup identici → nessun oggetto nuovo);
  - backup interrotto prima del manifest → invisibile, e la pulizia rimuove gli orfani;
  - tetto del pool;
  - ripristino che non sovrascrive.
- Prova manuale: backup reale di una cartella progetto verso OneDrive, ripristino di un file e di una cartella.

## Lasciato al builder

- Struttura interna dei tipi, formato JSON esatto del manifest, UI di dettaglio (icone, testi).
- Concorrenza e priorità I/O del backup (consigliato: priorità utility/background, un file alla volta o pochi in parallelo).
- Come mostrare l'avanzamento.
- Persistenza delle impostazioni (`UserDefaults` va bene).

## Differenze rispetto alla spec

Il testo sopra è il design approvato prima di scrivere il codice. Questo è quello che la 1.0 fa di diverso, ricavato da `CHANGELOG.md`, `README.md` e dal codice. Il formato dell'archivio come lo scrive il codice oggi è in [`docs/formato-archivio.md`](../../formato-archivio.md).

### Archivio

- **Nome della cartella dell'archivio**: non è più `<nome computer>` ma `<nome del Mac>-<id8>`, dove `id8` sono i primi 8 caratteri dell'UUID hardware (0.6.3: dopo Migration Assistant due Mac potevano scrivere nello stesso archivio). Gli archivi nuovi sono `<nome del Mac>-<id8>-<utente>`, così due account dello stesso Mac non condividono l'archivio; un nome già salvato resta quello (`AppPaths.archiveName` in `Sources/BackupMe/Settings.swift`). Rinominare il Mac non crea un archivio nuovo.
- **Proprietario in `repo.json`**: i campi `owner` (uid) e `ownerName` (nome breve dell'account). Un altro account dello stesso Mac non può scrivere in un archivio che non è suo; un archivio senza proprietario va al primo account che lo rivendica (`Sources/BackupCore/ArchiveOwner.swift`).
- **Cartella dell'archivio con permessi `0700`**: leggibile solo dall'account che la scrive, sui dischi che rispettano i proprietari dei file (exFAT, FAT32 e molte condivisioni SMB no); un archivio creato prima viene corretto (`Repository.archiveDirectory`).
- **Lock**: non contiene PID e host e non va rimosso a mano. È un `flock(2)` sul file `lock`, che il sistema rilascia quando il processo muore, quindi non restano lock vecchi. Sui dischi senza `flock` (alcuni exFAT e SMB) si procede senza lock.
- **Oggetti `.raw`**: accanto a `<hash>.lzfse` ci sono `<hash>.raw`, salvati così come sono quando la compressione risparmia meno del 5% o il file è di almeno 32 MB. Questi si copiano in streaming (con un clone APFS se si può) e non stanno mai in memoria per intero.
- **Checksum dell'indice** (0.9.2): ogni manifest nuovo comincia con `"check"`, lo SHA-256 del resto del JSON, così un indice danneggiato non viene letto come valido.
- **Formato più recente** (0.9.0): un archivio con `format` maggiore di quello che l'app conosce resta sfogliabile, ma l'app non lo scrive e non lo pulisce. Anche il kit di ripristino si ferma.
- **Scritture che non seguono i collegamenti** (0.9.4): se la cartella `BackupMe`, quella del Mac o una sua sottocartella è un collegamento simbolico, il backup si ferma invece di scrivere dove punta.

### Servizio e avvio

- **LaunchAgent invece di `SMAppService`**: con la firma ad-hoc `SMAppService.mainApp` non funzionava, e si è passati al ripiego già previsto. L'app scrive `~/Library/LaunchAgents/com.vale76p.BackupMe.plist` (`KeepAlive` solo dopo un'uscita non riuscita), quindi parte al login e si riavvia se va in crash, ma non dopo **Esci**. Le registrazioni `SMAppService` delle versioni precedenti vengono tolte (`Sources/BackupMe/SystemServices.swift`).
- App universale (Apple Silicon e Intel). Per compilarla servono Xcode 26 o i Command Line Tools su macOS 15.6 o successivo; per usarla basta macOS 14.
- Firma: ad-hoc di default, oppure con un certificato proprio (`BACKUPME_SIGN_IDENTITY`) perché macOS non richieda i permessi a ogni aggiornamento.

### Comportamento cambiato

- **Sorgente che contiene la destinazione** (0.7.0): è accettata invece di essere rifiutata. La destinazione, la Libreria, le cartelle cloud e il Cestino vengono esclusi in automatico quando sono dentro un elemento salvato. Resta rifiutata una sorgente che è la cartella `BackupMe` degli archivi o sta al suo interno.
- **Backup parziali**: se una sorgente manca o non si legge, se una sottocartella non si legge o se lo spazio è esaurito, le altre vengono salvate lo stesso. Il backup risulta non riuscito (notifica, icona di errore) e i motivi vanno negli avvisi del manifest. La pulizia continua ma non elimina mai l'ultimo backup completo.
- **Nessuna modifica, nessun indice nuovo**: se dall'ultimo backup non è cambiato niente non si scrive un altro manifest (lo si rilegge, e se è danneggiato se ne scrive uno nuovo).
- **Conservazione** (0.6.3): conta gli ultimi N giorni, settimane e mesi *che hanno un backup*, come restic, non a ritroso da oggi. Così un orologio avanti o un Mac rimasto spento a lungo non svuotano la storia. Il backup appena fatto è sempre protetto, anche dal tetto.
- **Pulizia degli oggetti** (0.9.1): una volta al giorno invece che dopo ogni backup, subito se c'è un tetto allo spazio.
- **Tetto allo spazio**: come nella spec, più due cose: protegge l'ultimo backup completo e, con il disco pieno, un file che non ci sta viene saltato senza copiarlo (backup parziale, 0.9.2–0.9.3).
- **Ripristino**: la finestra non è più il layout B a tre colonne. I backup stanno nella barra laterale, raggruppati per giorno con le ore come chip; i filtri Modificati, Eliminati e Nuovi hanno il conteggio, e un ispettore a destra mostra versioni, Anteprima, Confronta e Ripristina (0.9.0). Le regole "non sovrascrive mai" e "Sostituisci passa dal Cestino" sono rimaste; "Sostituisci" non viene offerto sull'archivio di un altro Mac e viene rifiutato se l'archivio sta dentro la cartella da sostituire.

### Funzioni aggiunte

- **Kit di ripristino** (0.6.0): `RIPRISTINO.command` e `LEGGIMI.txt` in `<destinazione>/BackupMe/`. Il ripristino funziona senza l'app e senza Xcode, solo con JavaScript for Automation e `shasum`. Lo script verifica ogni file, controlla il checksum dell'indice, chiede due conferme e non sovrascrive mai. Ha una versione propria (9 nella 1.0) e una versione vecchia non sostituisce un kit più nuovo.
- **Verifica a campione** (0.6.0): una volta al giorno si rileggono a caso fino a 100 MB dell'archivio, più l'indice più recente e uno scelto a caso. Un file danneggiato viene riparato dalla copia attuale, se esiste; altrimenti arriva un avviso. Non cancella mai niente.
- **Controllo completo** (0.8.0): *Impostazioni › Avanzate › Controlla ora* rilegge indici e oggetti usati, ripara dove può, e permette di eliminare i backup con l'indice illeggibile (0.9.3).
- **File singoli e profilo completo** (0.7.0): si salvano anche singoli file, oltre alle cartelle, e la cartella Inizio intera.
- **Cartelle cloud** (0.9.0): OneDrive, Dropbox, Google Drive, iCloud Drive, Box e gli altri client vengono rilevati sul Mac e proposti come destinazione. Le loro cartelle sono escluse dal backup del profilo, e i file iCloud "solo nel cloud" non vengono scaricati.
- **Controllo del caricamento nel cloud** (0.6.0): se il client non carica i backup da più di 3 giorni, o segnala un errore, arrivano un'icona e una notifica.
- **Rinvii** (0.6.0, 0.8.0): i backup pianificati aspettano con Risparmio energetico, batteria sotto il 20%, Mac troppo caldo, su una rete a consumo e, a scelta, per tutto il tempo a batteria. Non aspettano mai oltre 24 ore dall'ultimo backup riuscito.
- **Esclusioni** (0.6.0–0.8.0): pattern sul percorso (`apps/*/dist`), cartelle con `CACHEDIR.TAG`, cartelle o file precisi scelti dal Finder, file oltre una dimensione (mai dentro `.git`), file senza permessi di lettura saltati in automatico.
- **Repository git coerenti** (0.6.0): se durante il backup cambia un repository git, la cartella viene riletta; se cambia ancora, un avviso chiede di ripetere il backup.
- **Ripristino più ricco** (0.5.0–0.6.1): anteprima Quick Look, confronto con la versione attuale (FileMerge), ripristino di più elementi insieme, "Ripristina tutto il backup in…", trascinamento nel Finder.
- **Notifiche a livelli e registro** (0.8.0): solo problemi, anche gli avvisi, oppure ogni backup. Il registro su file (`~/Library/Application Support/BackupMe/BackupMe.log`) sopravvive ai riavvii.
- **Benvenuto** (0.4.0) al primo avvio, e la scheda della destinazione in stile Time Machine (0.6.2).
