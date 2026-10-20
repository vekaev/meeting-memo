#!/usr/bin/env bash
# Builds the Mac app, installs it to ~/Applications and restarts it so the newest version is always running.
# The running copy is asked to quit normally first, so its state is saved.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate --quiet
xcodebuild -project MeetingMemo.xcodeproj -scheme MeetingMemo -configuration Release \
  -destination "generic/platform=macOS" -derivedDataPath build -quiet build

APP="$HOME/Applications/Meeting Memo.app"
RUNNING='Meeting Memo\.app/Contents/MacOS/'
if pgrep -f "$RUNNING" >/dev/null; then
  osascript -e 'tell application id "com.yevheniipetrenko.MeetingMemo" to quit' || true
  # Saving can take a while; wait until it has really exited (up to 2 minutes).
  for _ in $(seq 1 480); do pgrep -f "$RUNNING" >/dev/null || break; sleep 0.25; done
  if pgrep -f "$RUNNING" >/dev/null; then echo "The running copy didn't quit; not replacing it."; exit 1; fi
fi

mkdir -p "$HOME/Applications"
rm -rf "$APP"
cp -R "build/Build/Products/Release/Meeting Memo.app" "$APP"
# Ad-hoc signatures change on every build, so macOS would ask for the microphone, calendar and screen-audio
# permissions again each time. A local Apple Development identity, when there is one, keeps them.
IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')"
[[ -n "$IDENTITY" ]] && codesign --force --sign "$IDENTITY" "$APP"
open "$APP"
for _ in $(seq 1 40); do pgrep -f "$RUNNING" >/dev/null && break; sleep 0.25; done
pgrep -f "$RUNNING" >/dev/null || { echo "Failed to start"; exit 1; }
echo "Meeting Memo restarted with the new build"
