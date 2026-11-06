# Changelog

Il formato segue [Keep a Changelog](https://keepachangelog.com/it/1.1.0/) e la numerazione [Semantic Versioning](https://semver.org/lang/it/). La versione si cambia in `Resources/Info.plist` (`CFBundleShortVersionString`, e `CFBundleVersion` +1 a ogni rilascio).

## [0.8.0] - 2026-11-06

### Aggiunto
- I file senza permessi di lettura ("non hai i privilegi necessari") vengono saltati in automatico ed elencati in Esclusioni invece di comparire tra gli avvisi (attivo di default). Pulsante "Cancella avvisi" per svuotare gli avvisi dell'ultimo backup.
- Esclusione dei file più grandi di un limite in GB, mai dentro `.git`; compaiono tra gli elementi esclusi come "troppo grande".
- Il backup pianificato aspetta su una rete a consumo (attivo di default) e, a scelta, per tutto il tempo in cui il Mac è a batteria.
- Notifiche a scelta: solo problemi, anche i backup con avvisi, o ogni backup completato.
- Pannello Registro: il registro di BackupMe salvato su file (sopravvive a riavvii e crash), con filtro "Solo errori", copia e svuota.
- Controllo completo dell'archivio da Avanzate: rilegge ogni indice e ogni file, segnala backup illeggibili, file mancanti e danneggiati, ripara quelli che hanno ancora la copia attuale. I backup aspettano la fine del controllo.

### Cambiato
- Finestra Sfoglia rifatta: i backup sono nella barra laterale, raggruppati per giorno con le ore come chip (i mesi più vecchi con i giorni), con i dati nuovi salvati e gli avvisi di ciascuno; il percorso cliccabile è nella barra degli strumenti; i filtri Modificati, Eliminati e Nuovi sono pulsanti con il conteggio; lo stato di ogni elemento è un'etichetta colorata; una barra in basso dice cosa si ripristina e da quale backup. Un ispettore a destra mostra i dettagli e tutte le versioni salvate del file scelto, con Anteprima, Confronta e Ripristina.
- Icona nella barra dei menu: freccia tonda durante il backup, badge giallo con gli avvisi, badge rosso con gli errori.
- I servizi cloud vengono rilevati sul Mac (OneDrive, Dropbox, Google Drive, iCloud Drive, Box e gli altri client in `~/Library/CloudStorage`, più le cartelle dei client vecchi nella Inizio): come destinazione si propongono solo quelli presenti, con un account per voce, e i testi nominano solo quelli. Gli archivi lasciati da un client rimosso ("Dropbox (data) Archive") non contano.

### Corretto
- Dopo aver cancellato e ricreato l'archivio nella stessa destinazione, ogni backup per 3 giorni avvisava "Pulizia rinviata: alcuni backup sono spariti". Ora un archivio nuovo (un nuovo id in `repo.json`) viene riconosciuto: la pulizia aspetta comunque per prudenza, ma senza avviso.

## [0.7.0] - 2026-11-06

### Aggiunto
- Si possono salvare anche singoli file, uno o più alla volta, oltre alle cartelle ("Aggiungi cartelle o file…"). Si ripristinano dall'app e da `RIPRISTINO.command` (kit versione 5).
- "Aggiungi profilo completo": salva tutta la cartella Inizio, file e cartelle. Un elemento già compreso in un altro lo segnala.
- Esclusioni automatiche: la destinazione dei backup, la Libreria (che contiene OneDrive, Dropbox e iCloud Drive con i file su richiesta, i dati delle app e le cache), le cartelle cloud e il Cestino non vengono salvati quando sono dentro un elemento salvato. Per questo un elemento che contiene la destinazione, come il profilo completo con OneDrive nella Libreria, ora è accettato invece di essere rifiutato. Un elemento aggiunto esplicitamente viene sempre salvato, anche se è dentro una di queste cartelle.
- Esclusione di cartelle o file precisi, scelti dal Finder, senza toccare gli altri con lo stesso nome.

### Cambiato
- Pannello Esclusioni rifatto: le regole sono un elenco con cosa colpisce ciascuna (cartelle, file e cartelle, percorso), si aggiungono una alla volta o dalle suggerite e valgono subito; sono rifiutate quelle vuote, doppie o che escluderebbero tutto (`*`). L'elenco delle cartelle escluse nell'ultimo backup dice per ogni cartella quale regola l'ha esclusa.

## [0.6.4] - 2026-11-06

### Cambiato
- Icona nella barra dei menu leggermente più marcata (peso medio invece di regolare).

### Corretto
- `scripts/build-app.sh` si fermava su un Mac gestito senza permessi di amministratore con "xattr: [Errno 1] Operation not permitted" (su `AppIcon.icns` e `Info.plist`): cercava di togliere tutti gli attributi estesi, compresi quelli di sistema come `com.apple.provenance` che lì non si possono togliere. Ora toglie solo quelli che `codesign` rifiuta (informazioni del Finder, resource fork, etichette della cartella sincronizzata) e non si ferma mai per un attributo.

## [0.6.3] - 2026-11-06

Correzioni dalla seconda revisione avversativa (integrità, ripristino, ciclo di vita, scala, interfaccia).

### Corretto: dati e sicurezza
- `RIPRISTINO.command` poteva scrivere fuori dalla cartella di destinazione con un indice manomesso: un collegamento `sub` e una cartella `Sub` sono lo stesso nome su APFS. Ora scrive solo nelle cartelle che ha creato e rifiuta nomi che differiscono solo per maiuscole o forma Unicode (kit versione 4).
- La pulizia poteva cancellare il contenuto di un backup ancora presente (anche l'unico) se il suo indice spariva e ricompariva durante una risincronizzazione del cloud.
- Un backup con l'orologio avanti poteva cancellare tutta la storia, e il tetto poteva poi eliminare il backup appena fatto. La conservazione ora conta gli ultimi giorni, settimane e mesi *che hanno un backup* (come restic) e il backup appena fatto è sempre protetto.
- Una sottocartella illeggibile dava un backup "riuscito" e la pulizia poteva eliminare gli ultimi che ne contenevano i file: ora il backup è parziale e l'ultimo completo resta protetto.
- Un `git gc` / `git maintenance` durante il backup poteva salvare un repository rotto: ora la cartella viene riletta.
- Dopo Migration Assistant due Mac potevano scrivere nello stesso archivio: il nome dell'archivio è legato all'identificativo hardware.
- Un indice con un hash non valido poteva far mostrare in anteprima un file locale qualsiasi; le anteprime e i trascinamenti non riusano più copie incomplete.
- "Sostituisci" non è più offerto sull'archivio di un altro Mac, né prima che sia pronto il controllo di cosa finirebbe nel Cestino.

### Corretto: servizio
- Dopo l'installazione BackupMe girava senza il servizio di login che lo riavvia in caso di errore: ora `build-app.sh --install` lo avvia come servizio, sostituisce l'app senza lasciare il Mac senza BackupMe se la copia fallisce e limita il tempo dell'aggiornamento del kit.
- Il servizio di login che puntava a un'app spostata non avviava niente al login: viene corretto a ogni avvio.
- Il permesso per le notifiche non veniva chiesto se la configurazione avveniva da Impostazioni.
- Uno stop del Mac durante un backup lungo sembrava un backup bloccato; "Interrompi" faceva ripartire il backup dopo un minuto; con un pannello di scelta file aperto non partiva nessun backup; cambiare destinazione ora avvia subito un backup; la verifica giornaliera non risulta più fatta quando non è stata possibile; una cronologia illeggibile viene messa da parte invece di essere sovrascritta.

### Corretto: Sfoglia backup
- Un filtro poteva nascondere l'elemento selezionato mentre Ripristina continuava ad agire su di esso.
- Il dialogo "Sostituisci" ora agisce sulla cartella che aveva al momento della pressione e la nomina nel titolo.
- Scegliere rapidamente più backup poteva bloccare l'app; una ricerca durante il cambio di computer mostrava risultati dell'altro; "Mostra nel backup" nella cartella già aperta non selezionava l'elemento; lo stato non si aggiornava dopo un ripristino; ⌘R e ⇧⌘R non funzionavano; un'anteprima lenta poteva sostituirne una più recente.
- Le esclusioni si salvano quando si smette di scrivere, non a ogni tasto.

### Prestazioni con progetti grandi
- L'impronta dei file grandi teneva in memoria tutto il file (2 GB per un file da 2 GB).
- La pulizia con tetto allo spazio non è più quadratica e non tiene in memoria un insieme di riferimenti per ogni backup.
- Un backup interrotto non perde più gli hash già calcolati: il tentativo successivo non rilegge tutto.
- La verifica giornaliera non supera più il suo budget leggendo un file grande.

## [0.6.2] - 2026-11-06

### Aggiunto
- Impostazioni › Destinazione: una scheda come quella di Time Machine con nome e posizione della destinazione (es. "TEST – Dropbox"), spazio disponibile e occupato dai backup, data del primo e dell'ultimo backup e prossimo backup ("Dopo il collegamento all'alimentazione" quando aspetta la batteria). Pulsanti "Mostra nel Finder" e "Cambia…".
- Registro di sistema con livello Info o Debug in Impostazioni › Avanzate: Debug aggiunge i dettagli di cartelle, esclusioni, scansione, pulizia, verifica, caricamento nel cloud e ripristini. Pulsanti per aprire Console e copiare il comando `log stream`.
- `RIPRISTINO.command` (kit versione 3): prima di scrivere mostra un riepilogo con le conseguenze (dove finisce ogni cartella, file, MB, spazio libero) e chiede due conferme, "[s/N]" e poi la parola RIPRISTINA; `--si` le salta. La versione del kit è stampata dallo script (`--versione`) e scritta in LEGGIMI.txt.
- `scripts/build-app.sh --install` dice da quale versione si aggiorna e aggiorna subito il kit di ripristino nella destinazione configurata, se quello presente è più vecchio (strumento `KitUpdater`).

### Cambiato
- Icona nella barra dei menu a 15 pt, come le icone di sistema; quando è tutto a posto la spunta è verde.
- Sfoglia backup è una finestra standard senza barra laterale: il backup si sceglie dal menu "Backup" nella barra degli strumenti, raggruppato per Oggi / Ieri / Ultimi 7 giorni / Più vecchi; il sottotitolo mostra il percorso della cartella aperta.

## [0.6.1] - 2026-11-06

### Aggiunto
- Sfoglia backup: trascinando un file nel Finder se ne ripristina una copia dove lo lasci, con il nome "… (ripristinato …)" per non sostituire mai l'originale.
- Sfoglia backup: Indietro e Avanti tra le cartelle con ⌘[ e ⌘], come nel Finder.
- Filtro "Aggiunti da allora": elementi che oggi ci sono nella cartella ma non in quel backup (escluse le cartelle che il backup salterebbe); un doppio clic li mostra nel Finder.
- Notifiche raggruppate in un'unica pila, con i pulsanti "Riprova" e "Apri Impostazioni" quando c'è un problema.
- Pannello: ⌘Q chiude BackupMe anche senza aprire il menu "…".
- Icona Liquid Glass (Icon Composer, `Resources/AppIcon.icon`) con le varianti chiara, scura, trasparente e tinta su macOS 26 e successivi; su macOS 14 e 15 si vede la versione piatta generata da actool.

### Corretto
- Una cartella salvata tramite collegamento simbolico risultava "modificata" anche senza cambiamenti.
- Un file `index.lock` lasciato da git dopo un crash faceva comparire l'avviso "il repository git è cambiato durante il backup" a ogni backup: ora contano solo i lock recenti.
- `scripts/build-app.sh` falliva a volte con "resource fork, Finder information, or similar detritus not allowed" quando il progetto è in una cartella sincronizzata (Documenti su iCloud): ora pulisce gli attributi prima di firmare e sulla copia installata.
- Due Mac con versioni diverse di BackupMe sulla stessa destinazione si riscrivevano a vicenda lo script di ripristino: ora una versione più vecchia non sostituisce quello più nuovo.

## [0.6.0] - 2026-11-06

### Aggiunto
- Controllo del caricamento nel cloud: se OneDrive, Dropbox o un altro client non carica i backup da più di 3 giorni, o segnala un errore, il pannello mostra un'icona e arriva una notifica (al massimo una al giorno). Se la cartella non è sincronizzata, o il client non indica lo stato, non dice nulla.
- Ripristino senza l'app: nella destinazione, accanto all'archivio, ci sono `RIPRISTINO.command` e `LEGGIMI.txt`. Lo script usa solo strumenti presenti in macOS (niente Xcode), verifica ogni file e non sovrascrive mai.
- Verifica a campione: una volta al giorno si rileggono fino a 100 MB dell'archivio; un file danneggiato viene riparato dalla copia attuale se esiste, altrimenti arriva un avviso. Niente viene mai cancellato.
- Avviso se nell'archivio mancano file usati dai backup.
- Impostazioni › Esclusioni elenca le cartelle escluse nell'ultimo backup; i pattern con "/" valgono per il percorso (es. `apps/*/dist`); le cartelle con `CACHEDIR.TAG` sono escluse.
- Impostazioni › Conservazione mostra quanti backup terrebbero le regole scelte e quanti verrebbero eliminati.

### Cambiato
- I backup pianificati aspettano con Risparmio energetico attivo, batteria sotto il 20% o Mac troppo caldo, mai oltre 24 ore dall'ultimo backup riuscito; il pannello dice perché.
- Un commit fatto durante il backup faceva salvare un repository git incoerente: ora la cartella viene riletta e, se cambia ancora, arriva un avviso.

## [0.5.0] - 2026-11-06

### Aggiunto
- Sfoglia backup › Anteprima: barra spaziatrice, doppio clic su un file o voce "Anteprima" aprono Quick Look sulla versione salvata. Il file viene estratto in una cartella temporanea (mai accanto all'originale); sopra i 200 MB chiede conferma.
- Ripristino di più elementi insieme: selezione multipla nella tabella, poi Ripristina o Ripristina in… (un solo pannello per tutti). Un elemento che non riesce non ferma gli altri.
- Confronto con oggi: filtro nella barra degli strumenti "Modificati da allora" / "Eliminati da allora"; le cartelle segnalano se contengono file modificati o non più presenti.
- Ricerca: colonna Stato e ambito "Solo eliminati" per ritrovare i file che esistono solo nei backup; doppio clic o "Mostra nel backup" apre la cartella in quel backup con il file selezionato. Se i risultati superano 500 lo dice.
- "Confronta con la versione attuale" per i file modificati: apre FileMerge (con Xcode) con la versione salvata e quella di oggi; l'unione va in un file temporaneo. Senza FileMerge mostra i due file nel Finder.
- "Ripristina tutto il backup in…" al primo livello, per portare tutte le cartelle su un Mac nuovo.

### Cambiato
- Sostituire una cartella intera ora avvisa prima quanti file sono cambiati dopo il backup e se il repository git ha commit o branch più recenti, che finirebbero nel Cestino. Il dialogo offre anche "Ripristina accanto".

## [0.4.0] - 2026-11-06

### Aggiunto
- Icona dell'app (rigenerabile con `swift scripts/make-icon.swift`).
- Finestra di benvenuto al primo avvio: cartelle, destinazione e frequenza in un solo passo, poi "Avvia il primo backup". Il permesso per le notifiche si chiede lì, non più all'avvio.
- Icona nella barra dei menu con lo stato: a posto, backup in corso, sospeso, errore, da configurare. VoiceOver legge lo stato.
- Pannello: menu "…" con Info su BackupMe, Impostazioni… (⌘,) ed Esci (⌘Q); scorciatoie ⌘O per Sfoglia e Invio per il pulsante principale; "Configura BackupMe…" quando mancano cartelle o destinazione.
- Impostazioni › Pianificazione: interruttore "Backup automatici", data del prossimo backup e, se le notifiche sono disattivate, un pulsante per aprire Impostazioni di Sistema.

### Cambiato
- Impostazioni è la finestra standard di macOS: pannelli come pannelli nella barra degli strumenti, ⌘, e voce nel menu dell'app, pulsanti di dimensione standard senza vetro. Spazio occupato con indicatore rispetto al tetto, conservazione con etichette leggibili ("Giornalieri: 15 giorni", "Disattivati"), conferma prima di ripristinare le esclusioni predefinite, errori nel corpo della sezione.
- Mentre Sfoglia backup, Impostazioni o il benvenuto sono aperti, BackupMe compare nel Dock, in ⌘-Tab e ha la sua barra dei menu; torna solo nella barra dei menu quando si chiude l'ultima finestra.
- Pannello: righe ad altezza fissa, cerchio di stato colorato invece del vetro su vetro, riquadri più grandi raggruppati in un unico vetro, pulsante principale più grande.
- Sfoglia backup: scelta del computer nella barra laterale, colonne ordinabili, icone vere dei file, colonna "Stato" (nascosta per l'archivio di un altro computer) calcolata una volta per cartella, scorciatoie ⌘↑ (cartella superiore), ⌘R (ripristina) e ⇧⌘R (ripristina in…), foglio "Versioni" nativo con caricamento e stato vuoto, "Nessuna destinazione" con "Apri Impostazioni…" al posto dell'avviso, titoli d'errore specifici; se la cartella aperta non esiste nel backup scelto si risale alla più vicina.

## [0.3.1] - 2026-11-06

### Corretto
- Un file piccolo riscritto mentre veniva salvato (database, log, file degli IDE) poteva finire nell'archivio con un contenuto diverso dalla sua impronta: ora viene letto una volta sola, non mappato in memoria.
- Un file grande che cambiava durante la copia poteva far cancellare una copia già nell'archivio e usata dai backup precedenti: ora la copia viene verificata prima di diventare definitiva e quella esistente non si tocca mai.
- "Sostituisci": se dopo aver spostato la cartella attuale nel Cestino non si riusciva a metterci la versione ripristinata (per esempio perché un IDE la ricreava subito), la versione ripristinata veniva cancellata. Ora resta accanto, con un messaggio che dice dove.
- Se una cartella da salvare veniva cancellata o rinominata, ogni backup era parziale e la pulizia non girava più, riempiendo la destinazione. Ora la pulizia gira e protegge l'ultimo backup completo.
- Dopo l'errore "Backup bloccato da più di 2 ore" ogni nuovo tentativo falliva con "Un altro backup è già in corso": ora non se ne avvia un altro finché quello bloccato non termina.
- Il Mac non va più in stop per inattività durante un backup.
- Sfoglia backup: durante una ricerca "Ripristina" non faceva nulla, e svuotare la ricerca riattivava il pulsante a ripristino in corso.
- Un backup senza modifiche sembrava non eseguito: il pannello ora dice "Nessuna modifica dal … · controllato …".
- Pulizia: il tetto allo spazio poteva cancellare backup con nomi non suoi, e i tempi di attesa per i backup spariti dalla destinazione usavano l'orologio invece della data del backup.

## [0.3.0] - 2026-11-06

### Cambiato
- Sfoglia backup riorganizzata: tabella con colonne Nome, Dimensione e Modificato (e Percorso, Backup del nella ricerca), menu contestuale sulle righe (Apri, Ripristina, Ripristina in…, Mostra versioni), solo elementi nativi della finestra. Le cartelle salvate sono il primo livello della tabella (si aprono con doppio clic, come nel Finder) al posto del menu "Cartella"; nella barra degli strumenti restano "Cartella superiore", la ricerca e un unico pulsante grande "Ripristina" con menu (Ripristina in…, Mostra versioni del file). Il titolo è la cartella aperta, con il percorso nel menu del titolo; il sottotitolo mostra la data del backup o l'avanzamento.
- Stati vuoti al posto di liste vuote o avvisi: nessun backup ancora, nessun backup selezionato, nessun risultato di ricerca.
- Pannello della barra dei menu: avvisi dell'ultimo backup e notifiche disattivate diventano icone nella riga del titolo; lo stato occupa sempre una riga (testo completo al passaggio del mouse).

### Corretto
- Pannello: premendo "Esegui backup ora" il pulsante sfarfallava e, a backup finito, la riga degli avvisi faceva crescere il pannello.
- Scegliendo come destinazione la cartella BackupMe o l'archivio del Mac al suo interno, veniva creato un nuovo archivio annidato nel vecchio e i backup precedenti sparivano da Sfoglia backup: ora si usa la cartella che li contiene.
- Sfoglia backup: vetro dentro le righe e capsula di vetro attorno a pulsanti di vetro causavano glitch; la barra in fondo si sovrapponeva al contenuto quando si nascondeva o mostrava la barra laterale; la ricerca spostava la lista e mostrava "nessun risultato" mentre si scriveva.

## [0.2.0] - 2026-11-06

### Aggiunto
- Pannello nella barra dei menu in Liquid Glass (macOS 26 e successivi): stato con icona colorata che diventa un indicatore di avanzamento durante il backup, etichetta "Sospeso" accanto al nome, pulsante principale per avviare o interrompere il backup, scorciatoie per Sfoglia, Sospendi/Riprendi e Impostazioni, versione dell'app.
- Impostazioni divise in pagine con barra laterale: Cartelle, Destinazione e spazio, Pianificazione, Conservazione, Esclusioni.
- Sfoglia backup: azioni di ripristino in una barra flottante, percorso ed etichette in capsule di vetro.

### Corretto
- Cambiare destinazione bloccava per 3 giorni la pulizia dei backup vecchi con l'avviso "l'elenco dei backup su OneDrive è incompleto", anche senza usare OneDrive: ora ogni destinazione ha il suo elenco e l'avviso non nomina più OneDrive.

- Nelle nuove Impostazioni "Aggiungi cartelle…" e "Ripristina predefinite" non rispondevano: una cartella rimossa non si poteva più riaggiungere.
- L'errore "Scegli cartelle e destinazione nelle Impostazioni" (icona !) restava anche dopo aver completato le impostazioni.

### Note
- Su macOS 14 e 15 l'app funziona come prima, con materiali e pulsanti standard al posto del vetro.

## [0.1.0] - 2026-11-05

### Aggiunto
- Prima versione: backup pianificati e su richiesta dalla barra dei menu, archivio deduplicato, conservazione giornaliera/settimanale/mensile, tetto allo spazio, esclusioni, ripristino senza sovrascrivere e sfoglia dei backup di altri Mac.
