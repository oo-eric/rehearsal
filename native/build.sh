#!/bin/bash
# Build the native apps.
#   ./build.sh          Mac app -> dist/OO-Rehearsal-mac.zip (universal: Intel + Apple silicon)
#   ./build.sh ios      iPad/iPhone build check (installing on a device goes through Xcode)
#
# Rebuild songs first if the charts changed:  python3 ../build.py
set -euo pipefail
cd "$(dirname "$0")"
command -v xcodegen >/dev/null || { echo "needs xcodegen: brew install xcodegen"; exit 1; }
xcodegen generate --quiet

if [[ "${1:-mac}" == "ios" ]]; then
  xcodebuild -project OORehearsal.xcodeproj -scheme OORehearsal-iOS -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO build | tail -1
  exit 0
fi

# generic destination = every arch in ARCHS. Without it Xcode builds only this Mac's arch.
xcodebuild -project OORehearsal.xcodeproj -scheme OORehearsal-macOS -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/dd build | tail -1
APP="build/dd/Build/Products/Release/OO Rehearsal.app"
archs=$(lipo -archs "$APP/Contents/MacOS/OO Rehearsal")
[[ "$archs" == *x86_64* ]] || { echo "ERROR: no Intel slice ($archs)"; exit 1; }
mkdir -p ../dist
rm -f ../dist/OO-Rehearsal-mac.zip
ditto -c -k --keepParent "$APP" ../dist/OO-Rehearsal-mac.zip
echo "archs: $archs"
echo "wrote ../dist/OO-Rehearsal-mac.zip ($(du -h ../dist/OO-Rehearsal-mac.zip | cut -f1))"
