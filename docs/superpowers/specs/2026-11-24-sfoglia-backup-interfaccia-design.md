# BackupMe — Sfoglia backup, la finestra nuova: design

Data: 2026-11-24 · Stato: approvata da Valentino il 2026-11-24; le righe segnate «aggiunto durante l'esecuzione» sono cambiate dopo, con la finestra già costruita.

Le scelte segnate **(Valentino)** le ha prese l'utente. Quelle segnate **(mia)** sono di chi ha scritto questo testo e vanno controllate. Tutto il resto è lasciato a chi costruisce.

## Perché

La finestra «Sfoglia backup…», rifatta in 0.9.0, funziona, ma Valentino le ha trovato due punti deboli:

- **La linea del tempo non si legge come tale.** I backup sono capsule con l'ora sola: per trovare un momento si leggono righe di numeri, e quanti dati ha salvato un backup sta solo nel suggerimento (in intestazione c'è il totale del giorno).
- **L'aspetto è quello di un pannello di utilità.** Gerarchia piatta, ispettore da 270 pt senza anteprima, «Ripristina» in due posti. In quale momento ci si trova lo dice solo la capsula blu.

Di tre direzioni mostrate in mockup (linea del tempo a sinistra, tempo in alto, viaggio nel tempo) ne ha scelta la prima: la finestra che c'è già, con la barra laterale che diventa una linea del tempo (Valentino).

I mockup sono in `docs/superpowers/mockups/2026-11-24-sfoglia-backup-direzioni.html` e si aprono nel browser.

## Cosa c'è già

- `RestoreView.swift` (953 righe): una `NavigationSplitView` con la barra laterale dei backup, il pannello centrale (filtri, `Table`, barra in fondo) e l'ispettore.
- `RestoreModel.swift`: legge l'archivio (due indici in memoria), calcola lo stato «Rispetto a oggi», cerca, elenca le versioni, ripristina.
- Dati già disponibili, senza toccare `BackupCore`:
  - `RestoreModel.snapshots`: identificativo e data di ogni backup.
  - `AppModel.history`: le ultime 50 esecuzioni di questo Mac (byte nuovi, avvisi, esito).
  - `RestoreModel.warningCount`: gli avvisi di un backup il cui indice è in memoria.
  - `AppModel.statusText`: la riga di stato del pannello della barra dei menu.
  - `Restorer.extract`: una copia temporanea di un file salvato, una per contenuto.

## Obiettivi

1. **La linea del tempo si legge come una linea del tempo** (Valentino). Ogni backup è un punto su una verticale, dal più recente, sotto intestazioni di giorno e di mese; accanto l'ora, i dati salvati e l'eventuale avviso.
2. **Si sa sempre in quale momento si è** (Valentino). Il pannello centrale porta data e ora del backup in grande.
3. **Aspetto da app moderna di macOS** (Valentino): gerarchia chiara, filtri come tag, ispettore più largo con anteprima.
4. **I pulsanti stanno in un solo posto.** Una barra in fondo dice su cosa agisce e offre Anteprima, Confronta con oggi e Ripristina.
5. **Nessuna funzione e nessuna regola di sicurezza cambiano.** «Non sovrascrive mai», «Sostituisci passa dal Cestino e solo dove è permesso», un ripristino alla volta per tutta l'app.

## Non-obiettivi

- Le altre due direzioni (tempo in alto; viaggio nel tempo).
- Funzioni nuove oltre a quattro: l'anteprima nell'ispettore, «Mostra nel Finder», la carta con lo stato del backup, la scelta della versione dalla barra.
- Cambiamenti a `BackupCore`, al formato dell'archivio, al kit di ripristino.
- Una ricerca più veloce o un indice dei nomi persistente.
- Impostazioni, pannello della barra dei menu, finestra di benvenuto.
- Tema, dimensioni dei caratteri o altre preferenze nuove.

## Cosa lo renderebbe un fallimento

- **Un ripristino che non fa quello che dice la barra**: agisce su un altro elemento, su un altro backup, su una versione diversa da quella scritta.
- **«Sostituisci» offerto dove oggi non lo è**, o senza il controllo e la conferma di oggi.
- **Una funzione o una scorciatoia di oggi che sparisce**: ⌘↑, ⌥⌘↑ e ⌥⌘↓, ⌘R, ⇧⌘R, spazio, trascinamento nel Finder, ordinamento e colonne, computer di origine, «Solo eliminati».
- **I clic nella barra laterale che sbagliano il bersaglio**: è il difetto per cui in 0.9.0 una `List` ha preso il posto di una vista disegnata a mano.
- **Scegliere backup in fretta e bloccare l'app**, o un'anteprima che estrae file grandi.
- **Vetro con glitch** in vista.

## Parole

- **Linea del tempo**: la barra laterale a sinistra, con la carta dello stato e l'elenco dei backup.
- **Titolo**: l'intestazione del pannello centrale, con data e ora del backup.
- **Barra**: la barra delle azioni in fondo.
- **Versione scelta**: la riga selezionata nell'elenco «Versioni» dell'ispettore.
- *Archivio*, *backup*, *indice*, *cartella salvata* (una sorgente) ed *elemento* (una riga della lista) come in `docs/formato-archivio.md` e nell'interfaccia.

## Come si comporta

### Finestra

- Restano tre colonne: linea del tempo, lista, ispettore. L'ispettore si apre e si chiude come oggi (pulsante nella barra degli strumenti, `restoreInspector`).
- La barra degli strumenti non cambia: Indietro e Avanti, percorso, computer di origine, ricerca.
- Dimensione predefinita **1100×700** invece di 1000×640, perché le due colonne laterali sono più larghe (mia). Larghezze (mia): linea del tempo 200–300 (ideale 250), ispettore 260–380 (ideale 310), lista almeno 440.

### Linea del tempo

- **Carta dello stato, in cima, solo per l'archivio di questo Mac** (mia). Ripete la riga di stato del pannello della barra dei menu: stesso testo (`AppModel.statusText`), stesso colore e stesso simbolo. Un clic porta all'ultimo backup e chiude la ricerca. Colore e simbolo oggi sono privati del pannello: diventano condivisibili. Nel mockup la carta diceva «Tutto a posto»; viene il testo del pannello, così le due parti dicono sempre la stessa cosa.
- **Elenco in una `List`**, mai in una vista a scorrimento disegnata a mano. Una sezione per giorno dell'ultima settimana («Oggi · 24 nov», «Ieri · 23 nov», «Domenica 22 nov»), poi una per mese («Novembre»): le sezioni di oggi, dal più recente. Le intestazioni restano fissate in alto mentre l'elenco scorre (mia).
- **Una riga per backup** (mia): un punto su una linea verticale che passa per tutti i punti, l'ora («15:00», ore e minuti), una barra lungua in proporzione ai byte nuovi e «+210 MB». Un backup con avvisi ha punto e barra arancioni e il simbolo di avviso. A destra dell'intestazione il totale dei dati del periodo, come oggi.
- **Da dove vengono i dati.** Byte nuovi e avvisi dalle ultime 50 esecuzioni di questo Mac, con la regola di oggi: conta l'esecuzione che ha scritto l'indice, non una che l'ha riusato. Avvisi anche dall'indice di un backup in memoria, ma solo per un backup di cui la cronologia non sa niente: per gli avvisi comanda la cronologia, così «Cancella avvisi» li toglie anche dalla linea del tempo, come oggi dai chip (Valentino, deciso durante l'esecuzione). Dove non ci sono dati (backup più vecchi di 50 esecuzioni, archivio di un altro computer) la riga ha solo punto e ora, e l'avviso dell'indice se il backup è in memoria. La barra è proporzionale al massimo dell'elenco (mia).
- **Non ci sono righe «senza dati»**: se non cambia niente non si scrive un indice nuovo. Se una riga ha 0 byte nuovi mostra la barra vuota e nessun numero.
- **Selezione** (mia): la riga del backup scelto è evidenziata; quando la scelta cambia da fuori (⌥⌘↑ e ⌥⌘↓, «Mostra nel backup», cambio di computer, apertura della finestra) l'elenco scorre per mostrarla.
- **Suggerimento e VoiceOver**: data completa, byte nuovi, avvisi, come oggi.
- Durante una ricerca la riga resta evidenziata; un clic su una riga chiude la ricerca e mostra quel backup, come oggi.
- Caricamento e «Nessun backup»: come oggi.
- **Nessun gruppo richiudibile** (mia): con la conservazione predefinita (14 giorni, 8 settimane, 12 mesi) e un backup ogni ora l'elenco ha circa 60 righe.

### Titolo e filtri

- Sopra la lista, tre righe (mia): «Stai guardando il backup di» in maiuscoletto; **«Ieri alle 15:00»** in grande; sotto «lunedì 23 novembre 2026 · +210 MB salvati · 1 avviso».
  - Data e ora: «Oggi alle 14:00», «Ieri alle 23:15», «Domenica 22 alle 20:00», «9 novembre alle 20:00».
  - Terza riga: la data estesa, poi i dati della riga della linea del tempo («+210 MB salvati», «1 avviso» o «3 avvisi»). Senza dati resta la data sola. Non si dice «parziale»: il conteggio degli avvisi non lo stabilisce.
- **Filtri come tag**: «Tutto», «Modificati 4», «Eliminati 1», «Nuovi 1». Sono il `ChangeFilter` e i conteggi di oggi; il tag attivo è scuro. La scritta «Confronto con oggi» sparisce: lo dice l'intestazione della colonna. Visibili come oggi: archivio di questo Mac, senza ricerca (mia).
- **In ricerca** (mia): il titolo è la ricerca tra virgolette («readme»); sotto «4 risultati» (e «i primi 500» quando l'elenco è troncato). I tag sono «Tutti» e «Solo eliminati», l'ambito di oggi.

### Lista dei file

- Resta la `Table` di oggi, con le stesse colonne (Nome, Rispetto a oggi, Dimensione, Modificato; in ricerca Percorso e Backup del), ordinamento, colonne che si nascondono, selezione multipla, trascinamento nel Finder, menu tasto destro, doppio clic e spazio.
- **Righe** (mia): icone 20 pt e, al posto delle capsule, etichette col testo colorato su fondo tenue: «Nuovo», «Modificato», «Eliminato», «Contiene modifiche», «Contiene eliminati».
- Il resto non cambia: regole dei filtri, elementi «Nuovi» (oggi sul disco e non nel backup), cartella che risale alla più vicina salvata.

### Ispettore

- **Nessuna selezione**: icona, «Nessuna selezione», «Seleziona un file per vederne dettagli e versioni».
- **Più elementi** (mia): icona, «3 elementi selezionati», «2 cartelle e 1 file · 2,4 MB» (la dimensione dei soli file), e la stessa riga d'invito.
- **Un elemento**:
  - icona grande, nome, etichetta dello stato («Modificato da allora», …);
  - Posizione, Modificato e, per un file, Dimensione: «15 KB allora · 18 KB oggi» nell'archivio di questo Mac, se il file esiste ancora (mia);
  - per un file, la carta d'anteprima in alto e l'elenco **Versioni** su una linea verticale: una riga per contenuto diverso, dal più recente, con «in questo backup» sotto la data di quella del backup guardato. Caricamento e «Cerca le versioni in tutti i backup» come oggi.
- **La versione scelta è uno stato della finestra**, non più dell'ispettore: è quella su cui agiscono Anteprima, Confronta con oggi e Ripristina. Vale la regola di oggi: la scelta segue il contenuto, parte da quella del backup guardato (o, se non c'è, dalla più recente) e non cambia se un backup più nuovo ne ha una uguale. Cambia selezione nella lista, cambia anche la versione scelta.
- **Nessun pulsante nell'ispettore.**

### Anteprima nell'ispettore

- **Automatica, fino a 20 MB** (Valentino: 20 milioni di byte, come conta l'app). Con un file selezionato la carta mostra il contenuto della **versione scelta** (mia):
  - un'immagine: l'immagine;
  - testo e codice: le prime righe, in caratteri a spaziatura fissa;
  - gli altri tipi: l'anteprima rapida di Quick Look, o, se non c'è, l'icona grande.
- **Sopra i 20 MB**, e per le cartelle: icona grande. Per un file resta il pulsante Anteprima della barra, con la conferma di oggi sopra i 200 MB.
- **Non blocca mai la finestra** (mia): l'estrazione va in un task separato, e una carta che arriva tardi non sostituisce una selezione più recente (la regola del token di Quick Look). Se l'estrazione non riesce resta l'icona grande: nessun avviso, una riga di debug nel registro.
- Se la versione scelta non è quella del backup guardato, sotto la carta c'è «Versione del 30 ott, 20:00» (mia).
- Ogni contenuto è estratto una volta, nella cartella temporanea delle anteprime; a svuotarla pensa il sistema.

### Barra

- **Capsula flottante** (Valentino): in fondo, staccata dai bordi, per tutta la larghezza di lista e ispettore; con l'ispettore chiuso, della lista sola.
- **A sinistra**: icona, nome e una riga che dice da dove (mia): «dal backup di ieri alle 15:00», oppure «versione del 30 ott, 20:00» quando la versione scelta è di un altro backup. Davanti a una data l'articolo è «del», come in «versione del»: «dal backup del 9 novembre alle 20:00» (Valentino, deciso durante l'esecuzione).
- **A destra**, secondo la selezione (mia):

| Selezione | Pulsanti |
|---|---|
| Un file modificato da allora | Anteprima · Confronta con oggi · Ripristina ▾ |
| Un altro file | Anteprima · Ripristina ▾ |
| Una cartella, più elementi, la cartella guardata | Ripristina ▾ |
| «Tutte le cartelle», niente selezionato | Ripristina tutto… |

- **Il clic su «Ripristina» fa quello che fa oggi** (Valentino):

| Dove | Selezione | Clic su «Ripristina» |
|---|---|---|
| Una cartella qualunque | Niente | La cartella guardata, accanto all'originale |
| | File o sottocartelle | Quelli, accanto all'originale |
| | Solo elementi «Nuovi» | Niente da ripristinare: al posto del pulsante c'è «Mostra nel Finder», che mostra dove sono oggi (mia, aggiunto durante l'esecuzione) |
| «Tutte le cartelle» | Una cartella salvata | Chiede come oggi, dopo il controllo: Sostituisci (dove è permesso), Ripristina accanto, Ripristina in… |
| | Niente | «Ripristina tutto…»: sceglie una cartella |
| Un file | Una versione scelta | Quella versione, accanto all'originale |

- **Menu «▾»** (mia): «Ripristina in…» (⇧⌘R); «Mostra nel Finder» (gli elementi da ripristinare che esistono ancora; spento se non ce ne sono); «Mostra versioni del file» (un file solo: apre l'ispettore). In ricerca «Mostra nel backup» prende il posto di «Mostra nel Finder».
- **Spento, con lo stesso aiuto di oggi**, durante un ripristino o il controllo della cartella. Quando non c'è niente da ripristinare il pulsante lascia il posto a «Mostra nel Finder». «Ripristino in corso…» e «Controllo della cartella attuale…» prendono il posto della riga a sinistra.
- Il menu tasto destro della lista resta com'è.
- **Vetro**: su macOS 26 e successivi la capsula è di vetro (`glassPanel`) e i suoi pulsanti stanno in un `GlassGroup`; su macOS 14 e 15 è una capsula opaca. **Ripiego** (mia): se dà glitch, la formula che li diede in 0.3.0, la capsula diventa la barra in fondo di oggi, fatta meglio.

### Ricerca

- La lista diventa l'elenco dei risultati di oggi. Ispettore e barra si comportano come per un file, con «dal backup di» quello del risultato.
- «Mostra nel backup» (doppio clic, menu tasto destro, menu della barra) fa come oggi: chiude la ricerca, apre la cartella e seleziona il file.

### Archivio di un altro computer

- Niente carta dello stato, niente tag di filtro, niente colonna «Rispetto a oggi» (nascosta, come oggi), niente «Confronta con oggi». Le righe della linea del tempo hanno solo ora e, se l'indice è in memoria, l'avviso.

### Stati vuoti

- «Nessuna destinazione», «Destinazione non collegata», «Nessun backup», «Scegli un backup», «Nessuna modifica» di un filtro, ricerca senza risultati: gli stessi testi di oggi, nel nuovo aspetto. Finché non c'è un backup da sfogliare la barra non si vede (mia).

## Errori e log

- Non cambiano: gli avvisi di oggi («Impossibile aprire il backup», «Ripristino non riuscito», «Anteprima non disponibile»), la notifica quando la finestra è chiusa, un ripristino alla volta per tutta l'app, le righe del registro.
- L'anteprima che non riesce non avvisa: solo una riga di debug nel registro.

## Vincoli

- macOS 14 o successivo; il vetro solo dietro `#available(macOS 26, *)`.
- La barra laterale è una `List`; il modello tiene in memoria due indici al più; ogni lettura dall'archivio è fuori dal thread principale.
- Italiano, con le parole di `docs/formato-archivio.md` e dell'interfaccia.
- **Il codice della finestra sta in cinque file** (Valentino). Nomi proposti (mia): `RestoreView.swift` (finestra, stato, azioni, ricerca, avvisi), `RestoreTimeline.swift`, `RestoreBrowser.swift` (titolo, filtri, lista), `RestoreInspector.swift`, `RestoreActionBar.swift`. `RestoreModel` cambia il meno possibile.
- L'app si compila ancora con `swift build --product BackupMe` e con `scripts/build-app.sh`.

## Come si capisce che funziona

### Regole pure, con test automatici (Valentino)

Le regole che non dipendono dall'interfaccia escono dalla finestra e vanno in un target di libreria **senza SwiftUI**, `RestoreRules` (nome mio), da cui dipende l'app e che `BackupCoreTests` può importare:

- **Linea del tempo**: sezione di ogni backup (giorni dell'ultima settimana, poi mesi; «Oggi» e «Ieri»), titolo della sezione, ordine dal più recente, etichetta dell'ora, larghezza delle barre, totale di una sezione.
- **Titolo**: «Oggi alle 14:00», «Ieri alle 23:15», «Domenica 22 alle 20:00», «9 novembre alle 20:00»; terza riga con dati, avvisi o niente.
- **Bersaglio del ripristino**: dati luogo, selezione visibile, elementi «Nuovi», risultato della ricerca e versione scelta, dicono cosa «Ripristina» ripristina, da quale backup, se chiede prima e se è spento. Un caso per riga delle due tabelle della barra, più: un filtro che nasconde una riga selezionata (non si ripristina), una versione scelta di un altro backup, una ricerca senza risultato selezionato.
- **Riga della barra**: nome, e «dal backup di» o «dal backup del» oppure «versione del».
- **Riepilogo della selezione multipla**: «2 cartelle e 1 file · 2,4 MB».
- **Date ai confini**, con un'ora e un fuso fissi: mezzanotte, cambio d'ora (giorni di 23 e 25 ore), cambio di mese e d'anno, due backup nella stessa ora.

### Prova manuale

Una checklist in un documento di prova, sul modello di `docs/prova-reale-rc1.md`, da fare con un archivio vero:

- linea del tempo: backup orari, giorni e mesi; clic; ⌥⌘↑ e ⌥⌘↓ con scorrimento; suggerimenti; VoiceOver legge la data completa;
- titolo e tag: conteggi; un filtro che nasconde la selezione;
- ispettore: immagine, testo, PDF, file sopra i 20 MB, versione scelta di un altro backup;
- barra: ogni riga delle due tabelle; «Sostituisci» solo dove è permesso; menu; ripristino in corso;
- ricerca: risultati, «Solo eliminati», «Mostra nel backup»;
- archivio di un altro computer; destinazione scollegata; nessun backup;
- trascinamento nel Finder, spazio, doppio clic, ⌘R, ⇧⌘R, ⌘↑, ⌘[ e ⌘];
- la capsula su macOS 26 o successivi; dove disponibile, anche su 14 o 15;
- scegliere in fretta molti backup non blocca l'app.

## Lasciato a chi costruisce

- Misure, colori, spaziature, animazioni; l'altezza delle righe della `Table` (se non si può alzare, restano quelle di oggi).
- Come disegnare la linea verticale tra un punto e l'altro dentro le righe di una `List`.
- Come riconoscere immagini, testo e codice per l'anteprima; quante righe di testo mostrare.
- Nomi di tipi e funzioni di `RestoreRules`.
- Dove stare l'estrazione per l'anteprima, dentro `RestoreModel`.

## Rischi noti

- **Vetro con glitch** (0.3.0): c'è il ripiego.
- **Anteprima su un archivio solo nel cloud**: la prima selezione può dover scaricare il file. La finestra non si blocca, la carta resta vuota finché non arriva.
- **`RestoreView` è al limite del type checker** (il commento nel codice: «as one chain the body is too big for the type checker»). Dividerlo in cinque file e in viste più piccole toglie il problema, ma ogni passo va compilato mentre si fa.
- **Chi era abituato al «Ripristina» dell'ispettore** deve usare la barra. Per questo la riga della barra cambia subito quando si sceglie una versione.
