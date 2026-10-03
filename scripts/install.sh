#!/bin/sh
# Build the fork in Release and replace /Applications/EdgeMark.app.
set -eu
set -o pipefail
cd "$(dirname "$0")/.."
DD=/tmp/edgemark-release
xcodebuild -project EdgeMark.xcodeproj -scheme EdgeMark -configuration Release \
  -derivedDataPath "$DD" CODE_SIGN_IDENTITY=- build | grep -E "error:|\*\* BUILD"
pkill -x EdgeMark || true
rm -rf /Applications/EdgeMark.app
cp -R "$DD/Build/Products/Release/EdgeMark.app" /Applications/
open /Applications/EdgeMark.app
