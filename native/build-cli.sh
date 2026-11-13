#!/bin/bash
# Build the Mac app with Command Line Tools only -- no Xcode, no xcodegen.
#
#   ./build-cli.sh          universal (Intel + Apple silicon) -> ../dist/OO-Rehearsal-mac.zip
#   ./build-cli.sh native   this Mac's arch only (faster; for a quick local test)
#
# build.sh is the Xcode path and stays the source of truth for project settings.
# This script mirrors project.yml's macOS target by hand: same bundle id, same
# deployment target, same ad-hoc signing. Keep them in step if project.yml changes.
#
# Rebuild songs first if the charts changed:  python3 ../build.py
set -euo pipefail
cd "$(dirname "$0")"

SDK=$(xcrun --show-sdk-path)
DEPLOY=12.0                                   # matches project.yml deploymentTarget.macOS
NAME="OO Rehearsal"
BUNDLE_ID=online.owneroperators.rehearsal.mac # matches project.yml
OUT=build/cli
APP="$OUT/$NAME.app"

case "${1:-universal}" in
  universal) TARGETS=(x86_64 arm64) ;;
  native)    TARGETS=("$(uname -m)") ;;
  *) echo "usage: $0 [universal|native]" >&2; exit 1 ;;
esac

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUT/obj"

# --- compile one binary per arch, then lipo them together -------------------
for arch in "${TARGETS[@]}"; do
  echo "compiling $arch..."
  swiftc -sdk "$SDK" -target "$arch-apple-macos$DEPLOY" -O \
    -o "$OUT/obj/bin-$arch" Shared/*.swift macOS/*.swift
done
if [[ ${#TARGETS[@]} -gt 1 ]]; then
  lipo -create "${TARGETS[@]/#/$OUT/obj/bin-}" -output "$APP/Contents/MacOS/$NAME"
else
  cp "$OUT/obj/bin-${TARGETS[0]}" "$APP/Contents/MacOS/$NAME"
fi
chmod +x "$APP/Contents/MacOS/$NAME"

# --- Info.plist: macOS/Info.plist with the Xcode build settings filled in ---
sed -e 's/$(DEVELOPMENT_LANGUAGE)/en/g' \
    -e "s/\$(EXECUTABLE_NAME)/$NAME/g" \
    -e "s/\$(PRODUCT_NAME)/$NAME/g" \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/g" \
    -e "s/\$(MACOSX_DEPLOYMENT_TARGET)/$DEPLOY/g" \
    macOS/Info.plist > "$APP/Contents/Info.plist"
# Keys Xcode would add from project.yml / the asset catalog.
plutil -insert CFBundleIconFile -string AppIcon "$APP/Contents/Info.plist"
plutil -insert NSSupportsAutomaticTermination -bool false "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"

# --- icon: the .appiconset PNGs -> AppIcon.icns (no actool in CLT) ----------
ICONSET="$OUT/AppIcon.iconset"
SRC=Shared/Assets.xcassets/AppIcon.appiconset
mkdir -p "$ICONSET"
cp "$SRC/mac-16.png"   "$ICONSET/icon_16x16.png"
cp "$SRC/mac-32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$SRC/mac-32.png"   "$ICONSET/icon_32x32.png"
cp "$SRC/mac-64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$SRC/mac-128.png"  "$ICONSET/icon_128x128.png"
cp "$SRC/mac-256.png"  "$ICONSET/icon_128x128@2x.png"
cp "$SRC/mac-256.png"  "$ICONSET/icon_256x256.png"
cp "$SRC/mac-512.png"  "$ICONSET/icon_256x256@2x.png"
cp "$SRC/mac-512.png"  "$ICONSET/icon_512x512.png"
cp "$SRC/icon-1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# --- the charts: songs.js (built by build.py) and the demo song, as plain resources ---
cp ../app/songs.example.js "$APP/Contents/Resources/"
if [[ -d ../midi ]]; then           # played parts (midi/<slug>-bass.mid)
  mkdir -p "$APP/Contents/Resources/midi" && cp ../midi/*.mid "$APP/Contents/Resources/midi/" 2>/dev/null || true
fi
if [[ -f ../app/songs.js ]]; then
  cp ../app/songs.js "$APP/Contents/Resources/"
else
  echo "note: no app/songs.js -- the app will show the demo song. Run: python3 ../build.py"
fi

# --- ad-hoc sign: copy to any Mac, right-click > Open once ------------------
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

archs=$(lipo -archs "$APP/Contents/MacOS/$NAME")
if [[ "${1:-universal}" == "universal" && "$archs" != *x86_64* ]]; then
  echo "ERROR: no Intel slice ($archs)"; exit 1
fi
mkdir -p ../dist
rm -f ../dist/OO-Rehearsal-mac.zip
ditto -c -k --keepParent "$APP" ../dist/OO-Rehearsal-mac.zip
echo "archs: $archs"
echo "app:   $(cd "$OUT" && pwd)/$NAME.app"
echo "wrote ../dist/OO-Rehearsal-mac.zip ($(du -h ../dist/OO-Rehearsal-mac.zip | cut -f1))"
