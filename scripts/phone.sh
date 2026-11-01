#!/bin/sh
# Builds the iPhone app without Xcode and installs it on the connected iPhone:
# swift build for iOS, bundle, sign with the free profile, install.
#
#   scripts/phone.sh            build, install, launch
#   scripts/phone.sh provision  first, and whenever the free 7-day profile has expired
#
# EDGEMARK_GITHUB_TOKEN needs contents read/write on owner/notes. Exported here, it,
# TYPESAFE_API_KEY and OPENAI_API_KEY reach the app at launch without showing in the command
# line; it keeps them in its Keychain. EDGEMARK_AGE_IDENTITY, the AGE-SECRET-KEY-1... of the Mac's
# note encryption, opens .age notes: the phone keeps it behind Face ID. Unset it after one run.
set -e
cd "$(dirname "$0")/.."
ID=io.github.jonaprieto.edgemark.ios
T=${TMPDIR:-/tmp}/edgemark-phone
APP=.build/ios/EdgeMark.app
VERSION=$(grep -m1 'MARKETING_VERSION' EdgeMark.xcodeproj/project.pbxproj | sed 's/.*= //; s/;//')
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo dev)
# The public half of the Mac's note encryption, so the phone can seal private notes.
RECIPIENT=$(defaults read io.github.ender-wang.EdgeMark encryption.recipient 2>/dev/null || true)
rm -rf "$T" && mkdir -p "$T"

xcrun devicectl list devices -q --json-output "$T/dev.json" >/dev/null
DEV=$(plutil -extract result.devices.0.hardwareProperties.udid raw "$T/dev.json" 2>/dev/null || true)
[ -n "$DEV" ] || { echo "no iPhone found: plug it in or join the same Wi-Fi, unlock, trust this Mac"; exit 1; }

if [ "$1" = provision ]; then
  # ponytail: the stub project exists only so Xcode's engine mints the free certificate and profile
  xcodebuild -project Phone/provision/P.xcodeproj -scheme Stub -destination "id=$DEV" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    -derivedDataPath "$T/dd" build -quiet
fi

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
build() { EDGEMARK_PHONE=1 swift build -c release --product EdgeMarkPhone --triple arm64-apple-ios26.0 --sdk "$SDK" --scratch-path .build/ios "$@"; }
build
BIN=$(build --show-bin-path)

# Xcode builds and provisions the WidgetKit extension; the main app stays a Swift package.
xcodebuild -project Phone/provision/P.xcodeproj -scheme EdgeMarkWidget -configuration Debug \
  -destination "id=$DEV" -derivedDataPath .build/phone-widget \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$VERSION" \
  SWIFT_OPTIMIZATION_LEVEL=-O build -quiet

rm -rf "$APP" && mkdir -p "$APP/PlugIns"
cp "$BIN/EdgeMarkPhone" "$APP/"
find "$BIN" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP/" \;
cp -R .build/phone-widget/Build/Products/Debug-iphoneos/EdgeMarkWidget.appex "$APP/PlugIns/"
cp EdgeMark/Resources/Mermaid/mermaid.min.js EdgeMark/Resources/Mermaid/LICENSE-mermaid.txt "$APP/"
sed -e "s/VERSION/$VERSION/" -e "s/>COMMIT</>$COMMIT</" -e "s/AGE_RECIPIENT/$RECIPIENT/" Phone/Info.plist > "$APP/Info.plist"

# Icon: one 1024px source; actool renders the sizes and the CFBundleIcons keys.
A="$T/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$A" && cp Phone/icon.png "$A/"
echo '{"images":[{"filename":"icon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}' > "$A/Contents.json"
xcrun actool "$T/Assets.xcassets" --compile "$APP" --platform iphoneos --minimum-deployment-target 26.0 \
  --target-device iphone --app-icon AppIcon --output-partial-info-plist "$T/icon.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Merge $T/icon.plist" "$APP/Info.plist"

PROFILE=$(ls -t ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision 2>/dev/null |
  while read -r f; do grep -q "\.$ID<" "$f" && { echo "$f"; break; }; done)
[ -n "$PROFILE" ] || { echo "no profile for $ID: run scripts/phone.sh provision"; exit 1; }
cp "$PROFILE" "$APP/embedded.mobileprovision"
security cms -D -i "$PROFILE" > "$T/profile.plist"
plutil -extract Entitlements xml1 -o "$T/ent.plist" "$T/profile.plist"
PREFIX=$(plutil -extract ApplicationIdentifierPrefix.0 raw "$T/profile.plist")
WIDGET_GROUP="$PREFIX.$ID.widget"
plutil -replace EdgeMarkWidgetAccessGroup -string "$WIDGET_GROUP" "$APP/Info.plist"
# Preserve the app's default keychain group, so installed tokens remain accessible.
/usr/libexec/PlistBuddy -c "Add :keychain-access-groups: string $WIDGET_GROUP" "$T/ent.plist"

# Sign with the keychain certificate the profile embeds; the name alone is ambiguous once old ones are revoked.
VALID=$(security find-identity -v -p codesigning | grep -v REVOKED)
N=$(plutil -extract DeveloperCertificates raw "$T/profile.plist")
CERT=
i=0
while [ $i -lt "$N" ]; do
  H=$(plutil -extract "DeveloperCertificates.$i" raw "$T/profile.plist" | base64 -d | shasum | cut -c1-40 | tr a-f A-F)
  echo "$VALID" | grep -q "$H" && { CERT=$H; break; }
  i=$((i + 1))
done
[ -n "$CERT" ] || { echo "no valid certificate for the profile: run scripts/phone.sh provision"; exit 1; }
codesign -f -s "$CERT" --entitlements "$T/ent.plist" "$APP"
codesign --verify --deep --strict "$APP"

xcrun devicectl device install app --device "$DEV" "$APP"
for k in EDGEMARK_GITHUB_TOKEN TYPESAFE_API_KEY OPENAI_API_KEY EDGEMARK_AGE_IDENTITY; do
  eval "v=\${$k:-}"
  if [ -n "$v" ]; then export "DEVICECTL_CHILD_$k=$v"; fi
done
xcrun devicectl device process launch --device "$DEV" "$ID" || echo "installed; unlock the phone and open EdgeMark"
