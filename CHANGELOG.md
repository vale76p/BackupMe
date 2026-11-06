# Changelog

Il formato segue [Keep a Changelog](https://keepachangelog.com/it/1.1.0/) e la numerazione [Semantic Versioning](https://semver.org/lang/it/). La versione si cambia in `Resources/Info.plist` (`CFBundleShortVersionString`, e `CFBundleVersion` +1 a ogni rilascio).

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
