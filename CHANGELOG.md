# Changelog

Il formato segue [Keep a Changelog](https://keepachangelog.com/it/1.1.0/) e la numerazione [Semantic Versioning](https://semver.org/lang/it/). La versione si cambia in `Resources/Info.plist` (`CFBundleShortVersionString`, e `CFBundleVersion` +1 a ogni rilascio).

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
