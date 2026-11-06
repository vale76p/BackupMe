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
xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true # actool sets the bundle bit there, codesign rejects it
# after actool, replacing its .icns: the hand-made one has every size and bolder strokes at 16/32px
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" # regenerate with scripts/make-icon.swift
# ad-hoc by default; set BACKUPME_SIGN_IDENTITY to a certificate name (even self-signed) so macOS keeps
# folder and notification permissions across rebuilds: an ad-hoc identity changes with every build
# the repo may live in a synced folder (Documents in iCloud) that keeps tagging the bundle: codesign rejects that
xattr -cr "$APP"
codesign --force --sign "${BACKUPME_SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x BackupMe || true
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/BackupMe.app"
    cp -R "$APP" "$HOME/Applications/"
    xattr -cr "$HOME/Applications/BackupMe.app" # ~/Applications isn't synced: once clean, it stays clean
    echo "Installed $HOME/Applications/BackupMe.app"
    open "$HOME/Applications/BackupMe.app" # pkill above stopped it: backups must keep running
fi
