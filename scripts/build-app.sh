#!/usr/bin/env bash
# Builds Meeting Memo (universal: Apple Silicon + Intel) and packages dist/MeetingMemo-mac.dmg.
#   scripts/build-app.sh            build the app and the .dmg
#   scripts/build-app.sh --install  also install to ~/Applications and launch
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen"; exit 1; }
xcodegen generate --quiet

xcodebuild -project MeetingMemo.xcodeproj -scheme MeetingMemo -configuration Release \
  -destination "generic/platform=macOS" -derivedDataPath build ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO -quiet build

APP="build/Build/Products/Release/Meeting Memo.app"
rm -rf dist && mkdir -p dist/dmg
cp -R "$APP" "dist/dmg/Meeting Memo.app"
ln -s /Applications dist/dmg/Applications
hdiutil create -quiet -volname "Meeting Memo" -srcfolder dist/dmg -ov -format UDZO "dist/MeetingMemo-mac.dmg"
rm -rf dist/dmg
echo "Built dist/MeetingMemo-mac.dmg"

[[ "${1:-}" == "--install" ]] && scripts/install-mac.sh || true
