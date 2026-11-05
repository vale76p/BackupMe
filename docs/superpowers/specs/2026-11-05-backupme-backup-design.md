# BackupMe — modulo Backup: design

Data: 2026-11-05 · Stato: bozza da approvare

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
