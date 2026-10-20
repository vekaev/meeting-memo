#!/bin/zsh
# Builds MeetingMemo.app and installs it to ~/Applications.
# Usage: ./build-app.sh            (build + install + launch)
#        ./build-app.sh --no-open  (build + install only)
set -euo pipefail
cd "${0:A:h}"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/MeetingMemo"

APP="build/MeetingMemo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/MeetingMemo"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# A stable signing identity keeps macOS privacy permissions across rebuilds.
IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')"
codesign --force --sign "${IDENTITY:--}" "$APP"

DEST="$HOME/Applications/MeetingMemo.app"
mkdir -p "$HOME/Applications"
pkill -x MeetingMemo 2>/dev/null && sleep 1 || true
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "Installed $DEST (signed with: ${IDENTITY:-ad hoc})"

[[ "${1:-}" == "--no-open" ]] || open "$DEST"
