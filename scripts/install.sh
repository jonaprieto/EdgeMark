#!/bin/bash
# Build the fork in Release and replace /Applications/EdgeMark.app.
set -eu
set -o pipefail
cd "$(dirname "$0")/.."
DD=/tmp/edgemark-release
xcodebuild -project EdgeMark.xcodeproj -scheme EdgeMark -configuration Release \
  -derivedDataPath "$DD" CODE_SIGN_IDENTITY=- build | grep -E "error:|\*\* BUILD"
# Quit politely so the app can flush pending sync work, then force it if it hangs.
osascript -e 'quit app "EdgeMark"' >/dev/null 2>&1 || true
for _ in $(seq 1 25); do
  pgrep -x EdgeMark >/dev/null || break
  sleep 1
done
pkill -x EdgeMark || true
rm -rf /Applications/EdgeMark.app
cp -R "$DD/Build/Products/Release/EdgeMark.app" /Applications/
open /Applications/EdgeMark.app
