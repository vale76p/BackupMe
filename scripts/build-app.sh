#!/bin/bash
# Builds build/BackupMe.app (ad-hoc signed). With --install, replaces ~/Applications/BackupMe.app.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product BackupMe
BIN="$(swift build -c release --show-bin-path)/BackupMe"
APP=build/BackupMe.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BackupMe"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# ad-hoc by default; set BACKUPME_SIGN_IDENTITY to a certificate name (even self-signed) so macOS keeps
# folder and notification permissions across rebuilds: an ad-hoc identity changes with every build
codesign --force --sign "${BACKUPME_SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x BackupMe || true
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/BackupMe.app"
    cp -R "$APP" "$HOME/Applications/"
    echo "Installed $HOME/Applications/BackupMe.app"
    open "$HOME/Applications/BackupMe.app" # pkill above stopped it: backups must keep running
fi
