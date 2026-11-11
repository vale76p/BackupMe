# BackupMe — contenitori (formato 2 dell'archivio): design

Data: 2026-11-12 · Stato: proposta, in attesa di approvazione.

Le scelte segnate **(Valentino)** le ha prese l'utente. Quelle segnate **(mia)** sono di chi ha scritto questo testo e vanno controllate. Tutto il resto è lasciato a chi costruisce.

## Perché

L'archivio di BackupMe sta in una cartella di OneDrive aziendale. Oggi ogni versione di ogni file salvato è un file a sé (`objects/xx/<sha256>.lzfse|.raw`). Con i backup ogni ora, i backup intermedi escono dopo 24 ore e la pulizia giornaliera cancella in un colpo tutti i file che solo loro usavano: centinaia o migliaia. OneDrive lo vede come un'eliminazione in massa e manda un'email di avviso all'utente. Succede spesso, è fastidioso e va tolto.

La soglia dell'email non è pubblica. Microsoft dice solo che scatta quando le eliminazioni in un'ora sono «più del solito». Quindi non esiste un numero sicuro: conta tenere le eliminazioni poche, piccole e regolari, ora per ora.

Il difetto di fondo è la quantità di file piccoli. Restic, Arq e Borg lo risolvono raggruppando i file piccoli in pochi file grandi. È quello che fa questo progetto.

## Cosa c'è già

Due modifiche fatte il 2026-11-12, non ancora committate, sono la premessa:

- La pulizia non è più forzata dopo un backup fallito (`AppModel.perform` non passa più `forceGC`): i file copiati restano per il tentativo successivo.
- Il Registro scrive a livello info quanti file elimina ogni pulizia.

## Obiettivi

1. **L'email non arriva più.** In nessuna ora BackupMe elimina dalla destinazione più file del tetto (sotto), di qualunque tipo, e le eliminazioni non si accumulano mentre OneDrive non sincronizza.
2. **I file nuovi vanno nei contenitori.** Da questa versione un backup non crea più file piccoli.
3. **Le due forme convivono (Valentino).** L'archivio esistente non si converte in un colpo e la cronologia non si perde. Backup, ripristino, verifica e kit leggono sia i file singoli sia i contenitori.
4. **I file piccoli esistenti spariscono da soli (Valentino).** Una conversione graduale, sul posto, li sposta nei contenitori senza che l'utente faccia niente. Il pannello mostra quanti ne restano e una stima della fine. **Il tetto vince sulla durata (mia):** giorni o settimane per un archivio di decine di migliaia di file piccoli, mesi per uno di centinaia di migliaia. La stima deve leggersi bene anche quando dice «8 mesi».
5. **Il ripristino senza l'app continua a funzionare.** `RIPRISTINO.command` ripristina un archivio misto su un Mac con macOS 14 di serie, con gli stessi strumenti di oggi (JavaScript for Automation e `/usr/bin/shasum`).
6. **Nessuna garanzia di oggi si perde:** verifica a campione e riparazione, «Controlla ora», attesa di 3 giorni quando i backup spariscono dalla destinazione, backup parziale che protegge l'ultimo completo, scritture atomiche senza seguire collegamenti.

## Non-obiettivi

- Cifratura, deduplicazione a blocchi, spezzare i file grandi.
- Cambiare il manifest, la conservazione o il tetto allo spazio.
- Un controllo nell'interfaccia per regolare il ritmo, o un pulsante «converti tutto ora» (farebbe partire l'email).
- Convertire gli archivi di altri Mac: ogni Mac converte solo il proprio.

## Cosa lo renderebbe un fallimento

- Un'ora in cui BackupMe elimina più file del tetto, anche una volta sola, anche durante la conversione, anche con i tentativi ripetuti dopo un backup fallito.
- Cronologia eliminata per fare posto a doppioni della conversione o a byte non più usati.
- Un oggetto leggibile che diventa illeggibile per colpa della conversione o della compattazione.
- Un file piccolo cancellato prima che il contenitore che lo contiene sia verificato e, dove il client lo dice, caricato nel cloud.
- Un kit che richiede strumenti non presenti in macOS di serie.
- Un backup orario che rilegge i riferimenti di tutti i manifest: con un milione di file sono minuti, ed è il motivo per cui oggi la raccolta è giornaliera.
- Un contenitore già pubblicato modificato sul posto: OneDrive lo ricaricherebbe per intero.

## Parole

- **Contenitore**: un file che contiene molti oggetti. Parola nuova per questo progetto: va aggiunta a `docs/formato-archivio.md` e, quando esisterà, al glossario.
- **Oggetto singolo**: un oggetto in un file suo, com'è oggi. Resta la forma dei file grandi.
- **File piccolo**: un oggetto singolo che, per dimensione, oggi andrebbe in un contenitore. È quello che la conversione fa sparire.

## Il formato 2

```
<archivio>/
  repo.json                 "format": 2
  objects/xx/<sha256>.lzfse|.raw     oggetti singoli (esistenti, e i file grandi)
  packs/
    <id>.pack               contenitore
    <id>.idx                indice del contenitore
  snapshots/                invariato
```

- **Un oggetto può stare in un file suo o in un contenitore, e chi legge cerca in entrambi.** Dove va un oggetto nuovo è una regola di chi scrive, non del formato: si può cambiare senza alzare `format`.
- **Regola di scrittura (mia):** un oggetto la cui forma salvata è sotto 4 MiB va in un contenitore; gli altri restano oggetti singoli. Un contenitore si chiude quando arriva a circa 32 MiB.
- **Il contenitore si descrive da solo (mia).** Ogni oggetto dentro è preceduto dal suo hash, dalla codifica (compresso o no) e dalla lunghezza, così l'indice si può ricostruire leggendo il contenitore. L'oggetto dentro ha gli stessi byte che avrebbe come oggetto singolo, e si verifica allo stesso modo: lo SHA-256 del contenuto è il suo nome.
- **L'indice accanto (`.idx`) ripete le posizioni (mia).** Serve a trovare un oggetto senza scaricare il contenitore: su OneDrive con i file solo online, leggere un pezzo di un file lo scarica tutto. Ha un checksum come i manifest. Se manca o è danneggiato si ricostruisce dal contenitore.
- **Contenitore e indice sono immutabili (mia).** Si scrivono con il meccanismo di oggi (`.tmp`, `fsync`, rinomina, senza seguire collegamenti) e non si toccano più. Il nome è un id che non si ripete; se usare lo SHA-256 del file è lasciato a chi costruisce.
- **`format` passa a 2** alla prima scrittura di questa versione. Un archivio di formato 1 si apre senza conversione.
- **Versioni vecchie.** Una versione precedente rifiuta di scrivere un archivio di formato 2 (già oggi: `newerFormat`) e, sfogliandolo, non trova gli oggetti nei contenitori. Va detto nel README e nel CHANGELOG.
- **Il kit** sale di versione, legge i formati 1 e 2, e si ferma con l'errore di oggi davanti a un formato più nuovo. Il kit vecchio rimasto nella destinazione rifiuta il formato 2 finché l'app non lo riscrive, cosa che fa da sola alla prima apertura.

La codifica byte per byte di contenitore e indice è lasciata a chi costruisce, con due vincoli: si legge da JavaScript for Automation senza strumenti esterni, ed è descritta in `docs/formato-archivio.md` con la stessa precisione del formato 1.

## Come si comporta

### Backup

- Gli oggetti nuovi sotto la soglia si accumulano nel contenitore aperto; quando è pieno si pubblica (contenitore, poi indice) e se ne apre un altro. L'ultimo si pubblica prima del manifest, che resta l'ultima scrittura.
- Un backup che fallisce o viene interrotto lascia i contenitori già pubblicati: il tentativo dopo ne riusa gli oggetti. Il contenitore non finito è un avanzo `.tmp` e sparisce come oggi.
- «Già nell'archivio» vale per un oggetto presente in una qualunque delle due forme.

### Il tetto alle eliminazioni

- **Un solo tetto, su tutto (mia):** manifest, oggetti singoli, contenitori e indici. Quello che non ci sta aspetta.
- **Si conta sull'ora, non sul backup (mia).** Il tetto vale per le eliminazioni degli ultimi 60 minuti, ricordate tra un avvio e l'altro: un backup fallito viene ritentato ogni 15 minuti e la pulizia gira dopo ogni tentativo, e «Esegui backup ora» ne aggiunge altri.
- **Valore di partenza: 50 file all'ora (mia).** Si cambia senza ricompilare, con una chiave nelle preferenze dell'app; nessun controllo nell'interfaccia.
- **Niente eliminazioni mentre il client è indietro (mia).** Con OneDrive in pausa o il Mac senza rete, le eliminazioni locali si sommerebbero e partirebbero tutte insieme al ritorno. Se l'ultimo manifest o l'ultimo contenitore pubblicato non risulta ancora caricato, in quel giro non si elimina niente. Dove il client non dice lo stato di caricamento vale il solo conteggio.
- **Tetto allo spazio (mia).** Resta morbido come oggi, quando gli oggetti non più usati aspettano la raccolta giornaliera. Quali backup eliminare si decide, come oggi, sui byte ancora usati: non si elimina mai cronologia per fare posto a doppioni o a byte morti. Se i byte usati ci stanno ma quelli su disco no, la compattazione diventa più severa (prima i contenitori con più byte morti) e la conversione non apre un contenitore nuovo. L'archivio rientra in qualche ora invece che subito; il pannello dice che sta rientrando, e l'avviso «il tetto è troppo basso» resta per il caso in cui non potrà rientrare mai.
- **Vale anche per la conservazione (mia).** Dopo un cambio di regole che elimina molti backup, i manifest escono a rate.
- **Non vale per «Elimina…»** dei backup illeggibili: è un gesto esplicito dell'utente e sono pochi file.
- **Ordine quando il tetto non basta (mia):** manifest della conservazione, poi quello che serve a rientrare nel tetto allo spazio, poi gli oggetti non più usati, poi la compattazione, poi la conversione.
- **Mentre la pulizia aspetta** (backup spariti dalla destinazione, i 3 giorni di oggi) non si elimina niente, nemmeno i doppioni della conversione.

### Pulizia e compattazione

- La raccolta completa resta giornaliera (`gcDue`): è il solo momento in cui si leggono i riferimenti di tutti i manifest. Produce un **piano** locale: cosa non è più usato, quali contenitori compattare, cosa convertire.
- Ogni backup esegue un pezzo del piano dentro il tetto.
- **Invariante:** niente che un backup fatto dopo il piano usa può essere eliminato. Prima di eliminare una voce del piano si controllano i riferimenti dei soli manifest comparsi dopo (nuovi, o tornati dopo essere spariti); se uno non si legge, in quel giro non si elimina niente. Il meccanismo è lasciato a chi costruisce, l'invariante no.
- **Compattazione (mia):** un contenitore senza oggetti usati si elimina. Uno con meno di metà dei byte ancora usati, o molto più piccolo della misura normale quando ce ne sono altri così, si riscrive: gli oggetti usati vanno in un contenitore nuovo, verificati uno per uno, e quello vecchio esce solo dopo la stessa conferma della conversione (sotto). I backup orari creano contenitori piccoli: la compattazione li unisce.
- **Un oggetto usato la cui unica copia è danneggiata non si butta mai:** il suo contenitore resta dov'è e il problema si segnala come oggi.

### Conversione

- Parte da sola, a ogni backup, finché esistono file piccoli.
- **Un contenitore alla volta (mia).** La conversione scrive un contenitore pieno di file piccoli (tetto in byte: su OneDrive con i file solo online, leggerli significa scaricarli), poi cancella quei file piccoli dentro il tetto alle eliminazioni, e apre il contenitore successivo solo quando ha finito. In mezzo l'oggetto sta in entrambe le forme, che è innocuo. Così i contenitori della conversione nascono pieni e non vanno ricompattati, e i doppioni non superano mai un contenitore (circa 32 MiB).
- **Prima quelli usati dal backup più recente (mia):** sono vivi di sicuro e si riconoscono leggendo un solo manifest. I file piccoli non più usati non si convertono: li elimina la pulizia.
- **Si cancella solo dopo la conferma:** il contenitore è stato riletto e ogni oggetto verificato, e il client cloud lo dà per caricato (lo stesso segnale che l'app legge già in `AppModel.uploadProblem`).
- **Dove il client non dice lo stato di caricamento (mia):** su un disco locale o una cartella non sincronizzata basta la verifica. In una cartella cloud riconosciuta (`CloudFolders`) il cui client tace, il file piccolo si cancella non prima del backup successivo e non prima di un'ora dalla pubblicazione del contenitore.
- Interrotta in qualunque punto, riprende senza perdere niente e senza rifare il lavoro già confermato.
- **Stima della durata:** con 50 file all'ora sono al massimo 1.200 file al giorno, meno quando pulizia e compattazione usano parte del tetto. Il numero di file piccoli dell'archivio reale non è noto: per questo la stima mostrata si calcola sul ritmo vero, non su una costante.

### Lettura, verifica, riparazione

- Se un oggetto esiste in più posti, vale qualunque copia che si verifica.
- La verifica a campione e «Controlla ora» coprono anche gli oggetti nei contenitori e la coerenza tra contenitore e indice. Un indice mancante o danneggiato si ricostruisce.
- La riparazione di un oggetto danneggiato dentro un contenitore lo salva di nuovo altrove dalla copia attuale, senza toccare il contenitore.
- La verifica dopo l'aggiornamento conosce `packs/` e tratta come estraneo quello che non è un contenitore o un indice.
- Lo spazio occupato (tetto, scheda Destinazione) conta oggetti singoli, contenitori, indici e manifest.

### Cosa vede l'utente

- **Impostazioni › Destinazione:** finché ci sono file piccoli, una riga con quanti ne restano e la stima della fine. Sparisce a conversione finita.
- **Registro:** per ogni backup che elimina qualcosa, una riga info con quanti file ha eliminato e quanti file piccoli restano. È il numero da confrontare con l'ora di un'eventuale email.
- Nessuna notifica nuova e nessuna impostazione nuova.

## Vincoli

- Swift, nessuna dipendenza, macOS 14, come oggi. Il nucleo sta in `Sources/BackupCore` e si prova senza l'app.
- Scala: un milione di oggetti. I test di prestazione esistenti (`PerformanceRC1Tests`) restano verdi; l'indice degli oggetti in memoria non deve costare più dell'elenco di oggi.
- Gli archivi di prova dei formati precedenti (`Fixtures/archive-0.8.0`, `0.9.4`, `1.0-rc1`) continuano a ripristinarsi. Serve un archivio di prova nuovo, misto.
- `docs/formato-archivio.md` diventa la descrizione del formato 2; README, CHANGELOG e `LEGGIMI.txt` del kit vanno aggiornati.

## Come si capisce che funziona

- Un archivio misto si ripristina per intero dall'app e dal kit, e il risultato è identico all'originale.
- In una simulazione di settimane di backup orari su un archivio di formato 1 con molti file piccoli, nessuna ora supera il tetto alle eliminazioni, i file piccoli arrivano a zero e ogni backup resta ripristinabile a ogni passo. Lo stesso con un backup che fallisce e viene ritentato ogni 15 minuti, e con il client che per ore non carica niente.
- Su un archivio al limite del tetto allo spazio la conversione va avanti senza eliminare un solo backup in più di quelli che la conservazione e il tetto eliminerebbero comunque.
- Un oggetto in attesa di eliminazione che un backup nuovo torna a usare non viene eliminato.
- Interrompendo in ogni punto (contenitore senza indice, indice senza contenitore, `.tmp` rimasti, conversione a metà) non si perde niente e il giro dopo riprende.
- Contenitore o indice danneggiati vengono scoperti dalla verifica; un oggetto usato non viene mai scartato dalla compattazione.
- Il kit vecchio rifiuta un archivio di formato 2 con un messaggio chiaro.
- Sul Mac aziendale: dopo l'installazione l'email non arriva più. Se arriva, il Registro dice quanti file ha eliminato quel backup e il tetto si abbassa.

## Lasciato a chi costruisce

- Codifica byte per byte di contenitore e indice; scelta dell'id.
- Indice in memoria e cache locale (accanto alla cache dei riferimenti in Application Support).
- Forma del piano e del controllo sui manifest nuovi.
- Soglie esatte della compattazione e tetto in byte della conversione.
- Come dividere il lavoro in passi e in che ordine rilasciarlo.
- Numero di versione dell'app.

## Rischi noti

- **La soglia di OneDrive è ignota.** 50 file all'ora è una stima prudente, non una garanzia. Il rimedio è il numero nel Registro e la chiave per abbassare il tetto.
- **Non è verificato che OneDrive aziendale dica lo stato di caricamento** dei file dell'archivio. Va controllato sul Mac aziendale prima di contare sulla regola «si cancella solo dopo il caricamento»: se il client tace vale la regola di ripiego, che è più debole.
- **Il numero di file piccoli dell'archivio reale è ignoto.** Decide la durata della conversione, non il disegno.
- **Ricaricamento.** La conversione ricarica una volta su OneDrive tutti i file piccoli, e la compattazione ricarica i byte ancora usati dei contenitori che riscrive.
- **Con i file solo online** la conversione e la compattazione scaricano quello che leggono: per questo hanno un tetto in byte.
- **Durante la conversione** l'archivio occupa fino a un contenitore in più: un oggetto copiato sta in due posti finché il file piccolo non viene cancellato.
- **Byte morti nei contenitori.** Un contenitore usato per più di metà non viene riscritto, quindi a regime una parte dello spazio (al massimo la metà dei contenitori, di solito molto meno) è occupata da versioni non più usate. Oltre il tetto allo spazio la compattazione li recupera.
