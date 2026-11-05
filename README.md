# BackupMe

Backup locale per macOS in stile Time Machine, gestito dalla barra dei menu. Pensato per Mac gestiti da MDM dove Time Machine è disabilitato: salva le cartelle dei progetti (`.git` incluso) in una cartella qualsiasi, tipicamente quella di OneDrive sincronizzata, che poi carica il client OneDrive.

- Backup pianificati (ogni 1–24 ore) e su richiesta
- Archivio deduplicato: ogni file è salvato una volta sola, anche in cento backup
- Conservazione: tutti nelle 24 h, poi giornalieri / settimanali / mensili configurabili
- Tetto massimo allo spazio occupato
- Ripristino di file o cartelle senza mai sovrascrivere

Design: [`docs/superpowers/specs/2026-11-05-backupme-backup-design.md`](docs/superpowers/specs/2026-11-05-backupme-backup-design.md)

## Requisiti

macOS 14 o successivo, con Xcode o i Command Line Tools (`xcode-select --install`; su un Mac gestito può servire l'IT per installarli). BackupMe non chiede mai permessi di amministratore.

## Compilare e installare

```bash
scripts/build-app.sh --install
```

Lo script compila, firma l'app, la copia in `~/Applications` e la riavvia. Per aggiornare, rilancia lo stesso comando.

**Permessi che non si perdono a ogni aggiornamento.** Con la firma ad-hoc predefinita ogni build è per macOS un'app nuova: l'accesso a Documenti/Scrivania può essere richiesto di nuovo, e finché non lo concedi i backup di quelle cartelle falliscono (il menu lo segnala). Per evitarlo crea una volta un certificato di firma del codice in *Accesso Portachiavi › Assistente certificato › Crea un certificato* (tipo "Firma codice") e compila con:

```bash
BACKUPME_SIGN_IDENTITY="Nome del certificato" scripts/build-app.sh --install
```

## Primo avvio

1. Clicca l'icona nella barra dei menu e scegli **Impostazioni…**
2. Aggiungi le cartelle da salvare e scegli la destinazione. Se c'è OneDrive, compare un pulsante **Usa OneDrive-…** per ogni account.
3. Concedi i permessi che macOS chiede: notifiche, e accesso a Documenti/Scrivania se le cartelle sono lì.

Il primo backup parte entro un minuto. Con **Esegui backup ora** lo avvii subito.

BackupMe gira come servizio dell'utente: al primo avvio si registra come LaunchAgent (`~/Library/LaunchAgents/com.vale76p.BackupMe.plist`), quindi parte a ogni login e viene riavviato se va in crash, ma non dopo **Esci**. Si disattiva da **Impostazioni › Avvia al login**.

### Come si comporta

- **Backup parziale.** Se una cartella sorgente manca o non è leggibile, le altre vengono salvate lo stesso, ma il backup è segnato come non riuscito: notifica, icona di errore e nessuna pulizia dei backup vecchi finché il problema resta.
- **Nessuna modifica, nessun upload.** Se dall'ultimo backup non è cambiato niente non viene scritto un nuovo indice su OneDrive.
- **Esclusioni.** Un nome (es. `node_modules`) esclude le cartelle con quel nome; i pattern con `*` o che iniziano con `.` (es. `*.log`, `.DS_Store`) valgono anche per i file. Dentro `.git` non si esclude mai niente.
- **File grandi** (oltre 32 MB) o non comprimibili vengono copiati così come sono, senza caricarli in memoria.

## Dove sono i backup

```
<destinazione>/BackupMe/<nome del Mac>-<id>/
  objects/     contenuto dei file (nome = hash; .lzfse compressi, .raw così come sono)
  snapshots/   un indice per ogni backup
```

`<id>` viene dall'identificativo hardware del Mac: due Mac con lo stesso nome non condividono mai l'archivio, e rinominare il Mac non ne crea uno nuovo.

I file non si leggono direttamente da OneDrive: si ripristinano con **Sfoglia backup…**. Da un altro Mac basta installare BackupMe, scegliere la stessa destinazione e aprire **Sfoglia backup…**, dove si può scegliere il computer di origine.

## Disinstallare

Esci dall'app, poi:

```bash
rm -rf ~/Applications/BackupMe.app ~/Library/Application\ Support/BackupMe ~/Library/LaunchAgents/com.vale76p.BackupMe.plist
defaults delete com.vale76p.BackupMe
```

I backup nella destinazione restano dove sono.

## Sviluppo

```bash
swift test
```

Il motore (`Sources/BackupCore`) non ha interfaccia ed è coperto da test; l'app (`Sources/BackupMe`) è solo UI e pianificazione.
