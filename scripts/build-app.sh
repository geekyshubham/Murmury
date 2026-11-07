#!/bin/sh
# Builds Murmury.app (release) into ./build and ad-hoc signs it.
# Usage: scripts/build-app.sh [--run] [--selftest] [--refresh-icon]
set -e
cd "$(dirname "$0")/.."
scripts/swift-build.sh -c release --product Murmury
BIN="$(scripts/swift-build.sh -c release --show-bin-path)/Murmury"
APP=build/Murmury.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Murmury"
refresh_icon=false
for option in "$@"; do [ "$option" != --refresh-icon ] || refresh_icon=true; done
if [ ! -f Resources/AppIcon.icns ] || [ "$refresh_icon" = true ] ||
   [ -n "$(find Sources/MurmuryKit/Views/Brand -name '*.swift' -newer Resources/AppIcon.icns -print -quit)" ]; then
    scripts/make-icon.sh
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/Models "$APP/Contents/Resources/Models"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# A stable identity keeps macOS permissions (Bluetooth, mic, camera, Accessibility) across
# rebuilds; ad-hoc signatures change every build. Create one with scripts/make-signing-cert.sh.
IDENTITY="Murmury Local Signing"
# Never fall back to ad-hoc silently: macOS would pin any permission granted to that one build
# (its cdhash), and the next build would quietly lose Accessibility while the switch still shows on.
if security find-identity -p codesigning | grep -q "$IDENTITY"; then SIGN="$IDENTITY"
elif [ "${MURMURY_ALLOW_ADHOC:-0}" = 1 ]; then SIGN="-"; echo "warning: ad-hoc signing; permissions granted to this build won't survive a rebuild" >&2
else
    echo "error: signing identity \"$IDENTITY\" isn't available (run scripts/make-signing-cert.sh, or unlock the login keychain)." >&2
    echo "       Set MURMURY_ALLOW_ADHOC=1 to build ad-hoc anyway." >&2
    exit 1
fi
codesign --force --sign "$SIGN" --entitlements Resources/Murmury.entitlements "$APP"
echo "Built $APP"
case "$1" in
  --run) open "$APP" ;;
  --selftest) "$APP/Contents/MacOS/Murmury" --selftest ;;
esac
