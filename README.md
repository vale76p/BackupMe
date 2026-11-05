# BackupMe

Backup locale per macOS in stile Time Machine, gestito dalla barra dei menu. Pensato per Mac gestiti da MDM dove Time Machine è disabilitato: salva le cartelle dei progetti (`.git` incluso) in una cartella qualsiasi, tipicamente quella di OneDrive sincronizzata, che poi carica il client OneDrive.

- Backup pianificati (ogni 1–24 ore) e su richiesta
- Archivio deduplicato: ogni file è salvato una volta sola, anche in cento backup
- Conservazione: tutti nelle 24 h, poi giornalieri / settimanali / mensili configurabili
- Tetto massimo allo spazio occupato
- Ripristino di file o cartelle senza mai sovrascrivere

Design: [`docs/superpowers/specs/2026-11-05-backupme-backup-design.md`](docs/superpowers/specs/2026-11-05-backupme-backup-design.md)

## Requisiti

macOS 14 o successivo, con Xcode o i Command Line Tools (`xcode-select --install`). Non servono permessi di amministratore.

## Compilare e installare

```bash
scripts/build-app.sh --install
open ~/Applications/BackupMe.app
```

Lo script compila, firma l'app ad-hoc (solo per uso locale) e la copia in `~/Applications`. Per aggiornare, rilancia lo stesso comando.

## Primo avvio

1. Clicca l'icona nella barra dei menu e scegli **Impostazioni…**
2. Aggiungi le cartelle da salvare e scegli la destinazione. Se c'è OneDrive, compare il pulsante **Usa OneDrive**.
3. Attiva **Avvia al login**.
4. Concedi i permessi che macOS chiede: notifiche, e accesso a Documenti/Scrivania se le cartelle sono lì.

Il primo backup parte entro un minuto. Con **Esegui backup ora** lo avvii subito.

## Dove sono i backup

```
<destinazione>/BackupMe/<nome del Mac>/
  objects/     contenuto dei file (compresso, nome = hash)
  snapshots/   un indice per ogni backup
```

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
