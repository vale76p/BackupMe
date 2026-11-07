# BackupMe

Backup locale per macOS in stile Time Machine, gestito dalla barra dei menu. Pensato per Mac gestiti da MDM dove Time Machine è disabilitato: salva le cartelle dei progetti (`.git` incluso) in una cartella qualsiasi, tipicamente quella di OneDrive sincronizzata, che poi carica il client OneDrive.

- Backup pianificati (ogni 1–24 ore) e su richiesta
- Archivio deduplicato: ogni file è salvato una volta sola, anche in cento backup
- Conservazione: tutti nelle 24 h, poi giornalieri / settimanali / mensili configurabili
- Tetto massimo allo spazio occupato
- Ripristino di file o cartelle senza mai sovrascrivere

Design: [`docs/superpowers/specs/2026-11-05-backupme-backup-design.md`](docs/superpowers/specs/2026-11-05-backupme-backup-design.md)

Novità per versione: [`CHANGELOG.md`](CHANGELOG.md)

## Requisiti

- **Per usarla:** macOS 14 o successivo, su Mac Apple Silicon o Intel (l'app è universale).
- **Per compilarla:** Xcode 26 o i suoi Command Line Tools (`xcode-select --install`), che richiedono macOS 15.6 o successivo: il codice usa le API di Liquid Glass, protette da `#available` per chi la usa su macOS 14. Su un Mac gestito può servire l'IT per installarli.

BackupMe non chiede mai permessi di amministratore.

## Compilare e installare

```bash
scripts/build-app.sh --install
```

Lo script compila, firma l'app, la copia in `~/Applications` e la riavvia. Per compilare bastano `Package.swift`, `Sources/`, `Resources/` e `scripts/build-app.sh`: `Tests/` e `docs/` servono solo allo sviluppo e si possono non copiare. Per aggiornare, scarica il codice nuovo (`git pull`) e rilancia lo stesso comando.

**Permessi che non si perdono a ogni aggiornamento.** Con la firma ad-hoc predefinita ogni build è per macOS un'app nuova: l'accesso a Documenti/Scrivania può essere richiesto di nuovo, e finché non lo concedi i backup di quelle cartelle falliscono (il menu lo segnala). Per evitarlo crea una volta un certificato di firma del codice in *Accesso Portachiavi › Assistente certificato › Crea un certificato* (tipo "Firma codice") e compila con:

```bash
BACKUPME_SIGN_IDENTITY="Nome del certificato" scripts/build-app.sh --install
```

## Primo avvio

1. Clicca l'icona nella barra dei menu e scegli **Impostazioni…**
2. Aggiungi le cartelle da salvare e scegli la destinazione. Se sul Mac c'è una sola cartella cloud (OneDrive, Dropbox, iCloud Drive…) compare il pulsante **Usa** con il suo nome; se ce ne sono più, per esempio OneDrive personale e aziendale, il menu **Usa una cartella cloud** le elenca tutte.
3. Concedi i permessi che macOS chiede: notifiche, e accesso a Documenti/Scrivania se le cartelle sono lì.

Il primo backup parte entro un minuto. Con **Esegui backup ora** lo avvii subito.

BackupMe gira come servizio dell'utente: al primo avvio si registra come LaunchAgent (`~/Library/LaunchAgents/com.vale76p.BackupMe.plist`), quindi parte a ogni login e viene riavviato se va in crash, ma non dopo **Esci**. Si disattiva da **Impostazioni › Pianificazione › Avvia al login**.

### Come si comporta

- **Backup parziale.** Se una cartella sorgente manca o non è leggibile, le altre vengono salvate lo stesso, ma il backup è segnato come non riuscito: notifica e icona di errore. La pulizia dei backup vecchi continua secondo la conservazione, ma l'ultimo backup completo non viene mai eliminato finché il problema resta.
- **Nessuna modifica, nessun upload.** Se dall'ultimo backup non è cambiato niente non viene scritto un nuovo indice su OneDrive.
- **Esclusioni.** Un nome (es. `node_modules`) esclude le cartelle con quel nome; un pattern con `/` vale per il percorso dentro la cartella salvata (es. `apps/*/dist`); i pattern con `*` o che iniziano con `.` (es. `*.log`, `.DS_Store`) valgono anche per i file. Sono escluse anche le cartelle con un file `CACHEDIR.TAG`. Dentro `.git` non si esclude mai niente. **Impostazioni › Esclusioni** mostra le cartelle escluse nell'ultimo backup. Si possono escludere anche i file sopra una dimensione scelta (mai dentro `.git`).
- **File senza permessi.** I file che macOS non lascia leggere ("non hai i privilegi necessari") vengono saltati ed elencati in **Impostazioni › Esclusioni** invece di comparire tra gli avvisi; si può disattivare. **Cancella avvisi** svuota gli avvisi dell'ultimo backup.
- **Repository git coerenti.** Se durante il backup si fa un commit, la cartella viene riletta; se cambia ancora, un avviso chiede di ripetere il backup.
- **Batteria, calore e rete.** I backup pianificati aspettano con Risparmio energetico, batteria sotto il 20%, Mac troppo caldo o su una rete a consumo (hotspot dell'iPhone, rete cellulare, Wi-Fi con «Modalità dati ridotti» attiva; si può disattivare), e a scelta per tutto il tempo a batteria, ma mai oltre 24 ore dall'ultimo riuscito. **Esegui backup ora** parte sempre, tranne durante **Controlla ora** o un ripristino.
- **Notifiche.** Problemi sempre; a scelta anche i backup con avvisi o ogni backup completato (**Impostazioni › Pianificazione**).
- **Registro.** **Impostazioni › Registro** mostra avvii, esiti, rinvii ed errori, anche dopo un riavvio (`~/Library/Application Support/BackupMe/BackupMe.log`, ruotato a 1 MB). Gli stessi messaggi vanno nel registro di sistema.
- **Cloud.** Se il client (OneDrive, Dropbox…) non carica i backup da più di 3 giorni, o segnala un errore, il pannello e una notifica lo dicono.
- **Verifica.** Una volta al giorno BackupMe rilegge a caso fino a 100 MB dell'archivio; un file danneggiato viene riparato dalla copia attuale se esiste, altrimenti arriva un avviso. Non cancella mai niente. **Impostazioni › Avanzate › Controlla ora** rilegge l'intero archivio: indici illeggibili, file mancanti o danneggiati.
- **File grandi** (oltre 32 MB) o non comprimibili vengono copiati così come sono, senza caricarli in memoria.

## Dove sono i backup

```
<destinazione>/BackupMe/<nome del Mac>-<id>-<utente>/
  repo.json    identità e formato dell'archivio
  objects/     contenuto dei file (nome = hash; .lzfse compressi, .raw così come sono)
  snapshots/   un indice per ogni backup
  lock         impedisce a due backup dello stesso Mac di scrivere insieme
```

**L'archivio non è cifrato:** chi può leggere la destinazione, o l'account cloud che la sincronizza, può leggere i file salvati, `.env` e chiavi comprese. Si salvano contenuto, permessi, data di modifica e symlink, ma non attributi estesi, ACL, tag del Finder e resource fork.

`<id>` viene dall'identificativo hardware del Mac e `<utente>` è l'account: due Mac con lo stesso nome, né due account dello stesso Mac, non condividono mai l'archivio, e rinominare il Mac non ne crea uno nuovo. Un archivio creato da una versione precedente tiene il suo nome, senza `-<utente>`.

La cartella dell'archivio è leggibile solo dal tuo account. Per ripristinare da un altro account, su un disco esterno che rispetta i proprietari dei file, attiva **Ottieni informazioni › Ignora la proprietà su questo volume** sul disco.

I file non si leggono direttamente da OneDrive: si ripristinano con **Sfoglia backup…**. Da un altro Mac basta installare BackupMe, scegliere la stessa destinazione e aprire **Sfoglia backup…**, dove si può scegliere il computer di origine.

**Senza l'app** (un Mac nuovo senza Xcode): in `<destinazione>/BackupMe/` ci sono `RIPRISTINO.command` e `LEGGIMI.txt`. Lo script usa solo strumenti di macOS:

```bash
sh "<destinazione>/BackupMe/RIPRISTINO.command"
```

Senza argomenti elenca computer e backup; con `<computer> <id del backup> <cartella>` ricrea le cartelle salvate dentro `<cartella>`, verificando ogni file e senza sovrascrivere niente.

## Se qualcosa va storto

- **Impostazioni › Registro** mostra avvii, esiti, rinvii ed errori, anche dopo un riavvio. Il file è `~/Library/Application Support/BackupMe/BackupMe.log` (più il precedente, `BackupMe.log.1`).
- **Impostazioni › Avanzate › Controlla ora** rilegge l'archivio e dice se è integro.
- Se l'app si chiude da sola, macOS salva il rapporto in `~/Library/Logs/DiagnosticReports/BackupMe-*.ips`.
- Lo stesso registro, con i dettagli di Debug, è nel registro di sistema:

```bash
log show --predicate 'subsystem == "com.vale76p.BackupMe"' --info --debug --last 1d
```

**Privacy:** registro e cronologia contengono i percorsi delle cartelle salvate, della destinazione e dei file che danno avvisi o vengono ripristinati. Restano su questo Mac, ma sono anche nel registro di sistema: su un Mac gestito l'IT può raccoglierlo. Il contenuto dei file non viene mai scritto nei registri.

## Disinstallare

Esci dall'app, poi:

```bash
launchctl bootout gui/$(id -u)/com.vale76p.BackupMe 2>/dev/null
rm -rf ~/Applications/BackupMe.app ~/Library/Application\ Support/BackupMe ~/Library/LaunchAgents/com.vale76p.BackupMe.plist
defaults delete com.vale76p.BackupMe
tccutil reset All com.vale76p.BackupMe
```

`tccutil` toglie i permessi concessi (notifiche, Documenti/Scrivania). Se avevi spostato l'app in `/Applications`, cancella anche `/Applications/BackupMe.app`.

I backup nella destinazione restano dove sono, insieme a `RIPRISTINO.command` e `LEGGIMI.txt` per ripristinarli senza l'app.

## Sviluppo

```bash
swift test
```

Il motore (`Sources/BackupCore`) non ha interfaccia ed è coperto da test; l'app (`Sources/BackupMe`) è solo UI e pianificazione.
