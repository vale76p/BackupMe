#!/bin/bash
# Builds build/BackupMe.app (ad-hoc signed). With --install, replaces ~/Applications/BackupMe.app.
set -euo pipefail
cd "$(dirname "$0")/.."

# codesign rejects Finder info and resource forks ("detritus"), which synced folders and actool add: only those
# are removed. `xattr -c` would also try system attributes such as com.apple.provenance, which on a managed Mac
# can't be removed without admin rights ("Operation not permitted") and don't bother codesign anyway.
strip_detritus() {
    find "$1" -print0 2>/dev/null | while IFS= read -r -d '' f; do
        for a in com.apple.FinderInfo com.apple.ResourceFork 'com.apple.fileprovider.fpfs#P'; do
            xattr -d "$a" "$f" 2>/dev/null || true
        done
    done || true # never a reason to stop: codesign right after says if something that matters is left
}

swift build -c release --product BackupMe
swift build -c release --product KitUpdater
BIN="$(swift build -c release --show-bin-path)/BackupMe"
APP=build/BackupMe.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BackupMe"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Liquid Glass icon (macOS 26+, dark/clear/tinted) into Assets.car; actool exits 0 even on failure,
# so success means it wrote Assets.car and named the icon in its partial Info.plist
PARTIAL="$(mktemp -t backupme-icon)"
ACTOOL_LOG="$(xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 14.0 --app-icon AppIcon --output-partial-info-plist "$PARTIAL" \
    --output-format human-readable-text --errors --warnings 2>&1)" || true
if [[ -f "$APP/Contents/Resources/Assets.car" ]] && ICON_NAME="$(plutil -extract CFBundleIconName raw "$PARTIAL" 2>/dev/null)"; then
    plutil -replace CFBundleIconName -string "$ICON_NAME" "$APP/Contents/Info.plist"
else
    echo "$ACTOOL_LOG" >&2
    echo "warning: could not compile Resources/AppIcon.icon, the app gets only AppIcon.icns (no Liquid Glass)" >&2
    rm -f "$APP/Contents/Resources/Assets.car"
fi
rm -f "$PARTIAL"
# after actool, replacing its .icns: the hand-made one has every size and bolder strokes at 16/32px
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" # regenerate with scripts/make-icon.swift
# ad-hoc by default; set BACKUPME_SIGN_IDENTITY to a certificate name (even self-signed) so macOS keeps
# folder and notification permissions across rebuilds: an ad-hoc identity changes with every build
# actool sets the bundle bit in Finder info, and a synced folder (Documents in iCloud) keeps tagging the bundle
strip_detritus "$APP"
codesign --force --sign "${BACKUPME_SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    OLD="$(defaults read "$HOME/Applications/BackupMe.app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true)"
    NEW="$(defaults read "$PWD/$APP/Contents/Info.plist" CFBundleShortVersionString)"
    AGENT="$HOME/Library/LaunchAgents/com.vale76p.BackupMe.plist"
    # the copy launchd supervises goes first: with KeepAlive it would be restarted while the app is replaced
    launchctl bootout "gui/$(id -u)/com.vale76p.BackupMe" 2>/dev/null || true
    pkill -x BackupMe || true
    mkdir -p "$HOME/Applications"
    # copied beside and then swapped: a copy that fails halfway must not leave this Mac without BackupMe
    NEXT="$HOME/Applications/.BackupMe-nuova.app"
    rm -rf "$NEXT"
    cp -R "$APP" "$NEXT"
    strip_detritus "$NEXT" # ~/Applications isn't synced: once clean, it stays clean
    rm -rf "$HOME/Applications/BackupMe.app"
    mv "$NEXT" "$HOME/Applications/BackupMe.app"
    echo "Installed $HOME/Applications/BackupMe.app"
    if [[ -n "$OLD" && "$OLD" != "$NEW" ]]; then echo "Aggiornamento da $OLD a $NEW"; fi
    # under launchd when the login agent is on, so KeepAlive restarts it after a crash from now on, not only
    # after the next login; otherwise a plain launch (backups must keep running after pkill above)
    if [[ -f "$AGENT" ]] && launchctl bootstrap "gui/$(id -u)" "$AGENT" 2>/dev/null; then
        echo "Avviato come servizio di login (riavviato da macOS se si chiude per errore)"
    else
        open "$HOME/Applications/BackupMe.app"
    fi
    # an upgrade may bring a new restore script: beside the archives now, not at the next backup. Time-limited:
    # an unreachable network destination must not hang the install
    perl -e 'alarm 60; exec @ARGV' "$(swift build -c release --show-bin-path)/KitUpdater" \
        || echo "Kit di ripristino non aggiornato ora: lo farà il prossimo backup"
fi
