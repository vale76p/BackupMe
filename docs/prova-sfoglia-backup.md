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
- [ ] Le sezioni sono «Oggi · …», «Ieri · …», i giorni della settimana, poi i mesi; dal più recente. Scorrendo, le intestazioni restano ferme in alto.
- [ ] I backup più vecchi delle ultime 50 esecuzioni, e quelli dell'archivio di un altro computer, hanno solo punto e ora.
- [ ] Il suggerimento e VoiceOver leggono data completa, MB e avvisi.
- [ ] ⌥⌘↑ e ⌥⌘↓ cambiano backup e l'elenco scorre fino a mostrarlo; un clic su una riga non fa scorrere niente.
- [ ] Un clic sul bordo sinistro e su quello destro di una riga sceglie proprio quella riga.
- [ ] Scegliere molti backup in fretta non blocca l'app.
- [ ] Durante una ricerca, un clic su una riga chiude la ricerca e mostra quel backup.

## Titolo e filtri

- [ ] Sopra la lista: «Stai guardando il backup di», «Ieri alle 15:00», «lunedì 23 novembre 2026 · +210 MB salvati · 1 avviso» (senza dati resta la data sola).
- [ ] I tag Tutto, Modificati, Eliminati, Nuovi filtrano allo stesso modo di prima. «Modificati», «Eliminati» e «Nuovi» mostrano gli stessi conteggi di prima; «Tutto» il totale delle righe della cartella (prima non aveva un numero).
- [ ] Un filtro che nasconde una riga selezionata la deseleziona: la barra non la elenca più.
- [ ] Con l'archivio di un altro computer: niente carta, niente tag, niente colonna «Rispetto a oggi».

## Lista dei file

- [ ] Ordinamento delle colonne, colonne che si nascondono, selezione multipla.
- [ ] Doppio clic: una cartella si apre, un file va in anteprima. Spazio apre e chiude Quick Look.
- [ ] ⌘↑ (cartella superiore), ⌘[ e ⌘] (indietro e avanti).
- [ ] Trascinare un file nel Finder ne ripristina una copia, col nome «… (ripristinato …)».
- [ ] Le etichette sono Nuovo, Modificato, Eliminato, Contiene modifiche, Contiene eliminati.

## Ispettore

- [ ] Niente selezionato: «Nessuna selezione». Più elementi: «N elementi selezionati» con il riepilogo (cartelle, file, dimensione).
- [ ] Un'immagine, un file di testo e un PDF mostrano il contenuto nella carta; un file sopra i 20 MB mostra l'icona.
- [ ] Un file di testo con fine riga alla Windows (un CSV esportato da Excel, un `.bat`) mostra le sue prime righe nella carta, non una riga sola.
- [ ] Scorrere con le frecce da un file all'altro: la carta non mostra per un attimo la versione scelta nel file precedente.
- [ ] Scegliere una versione la evidenzia e cambia la riga della barra in «versione del …»; la carta mostra quella versione.
- [ ] «Cerca le versioni in tutti i backup» legge gli altri backup come prima.
- [ ] Selezionare molti file in fretta non blocca la finestra, e una carta lenta non sostituisce una selezione più recente.
- [ ] Un file che non si può estrarre lascia l'icona, senza avvisi.

## Barra delle azioni

- [ ] Dentro una cartella, niente selezionato: il nome della cartella; «Ripristina» la ripristina accanto all'originale.
- [ ] Un file modificato da allora: Anteprima · Confronta con oggi · Ripristina ▾. Un file non modificato: Anteprima · Ripristina ▾.
- [ ] Una cartella salvata per intera: «Ripristina» chiede come prima (Sostituisci, Ripristina accanto, Ripristina in…), con il conto di quello che finirebbe nel Cestino.
- [ ] «Sostituisci» non compare per l'archivio di un altro computer, né per una cartella che questo Mac non salva.
- [ ] A «Tutte le cartelle», niente selezionato: «Ripristina tutto…» chiede una cartella.
- [ ] Solo elementi «Nuovi»: «Niente da ripristinare qui», e «Mostra nel Finder» al posto del pulsante: lo si preme e il Finder mostra quei file dove sono oggi.
- [ ] Più elementi: «N elementi», la dimensione, «Ripristina ▾».
- [ ] Menu «▾»: «Ripristina in…»; «Mostra nel Finder» (spento se non c'è più niente da mostrare); «Mostra versioni del file» (solo con un file).
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
- [ ] Senza risultati, e con «Solo eliminati» senza risultati: i testi di prima.

## Stati vuoti

- [ ] Nessuna destinazione (con «Apri Impostazioni…»), destinazione non collegata, nessun backup, scegli un backup: i testi di prima, e la barra non si vede.
- [ ] Un disco esterno scollegato e ricollegato mentre la finestra è aperta: la finestra se ne accorge.

## Cosa non è passato

(una riga per ogni problema: cosa si è fatto, cosa si è visto)
