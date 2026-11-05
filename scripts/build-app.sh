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
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x BackupMe || true
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/BackupMe.app"
    cp -R "$APP" "$HOME/Applications/"
    echo "Installed $HOME/Applications/BackupMe.app"
fi
