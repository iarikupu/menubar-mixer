#!/bin/sh
# Builds "Menubar Mixer.app" next to this script.
#   ./make-app.sh               build + ad-hoc sign (this Mac's architecture)
#   ./make-app.sh --install     also copy to ~/Applications and launch it from there
#   ./make-app.sh --release     universal (Apple silicon + Intel) build, zipped into dist/ for sharing
set -e
cd "$(dirname "$0")"

APP="Menubar Mixer.app"
BUNDLE_ID="local.menubarmixer.app"
VERSION="1.0"

INSTALL=0; RELEASE=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --release) RELEASE=1 ;;
        *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ $RELEASE = 1 ]; then
    # SwiftPM's multi-arch build needs full Xcode, so build the Intel slice on its own and merge.
    swift build -c release --triple x86_64-apple-macosx14.4 --scratch-path .build/x86
    lipo -create .build/release/MenubarMixer .build/x86/release/MenubarMixer -output "$APP/Contents/MacOS/MenubarMixer"
else
    cp .build/release/MenubarMixer "$APP/Contents/MacOS/MenubarMixer"
fi

rm -rf .build/AppIcon.iconset
swiftc -o .build/make-icon tools/make-icon.swift
.build/make-icon .build/AppIcon.iconset
iconutil -c icns .build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Menubar Mixer</string>
  <key>CFBundleDisplayName</key><string>Menubar Mixer</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>MenubarMixer</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.4</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAudioCaptureUsageDescription</key><string>Menubar Mixer captures each app's audio so it can change that app's volume. The audio stays on your Mac and is played straight back out.</string>
</dict></plist>
PLIST

# Ad-hoc signature. The explicit designated requirement (identifier only) means the signature doesn't
# bake in this build's code hash, which gives macOS the best chance of keeping the audio permission
# across rebuilds. If it ever asks again after a rebuild, just allow it and restart the app once.
codesign --force --sign - --identifier "$BUNDLE_ID" \
    -r="designated => identifier \"$BUNDLE_ID\"" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"

if [ $RELEASE = 1 ]; then
    mkdir -p dist
    ZIP="dist/Menubar-Mixer-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Packaged $ZIP ($(lipo -archs "$APP/Contents/MacOS/MenubarMixer"))"
fi

if [ $INSTALL = 1 ]; then
    mkdir -p "$HOME/Applications"
    pkill -x MenubarMixer 2>/dev/null || true
    sleep 0.5
    rm -rf "$HOME/Applications/$APP"
    cp -R "$APP" "$HOME/Applications/$APP"
    open "$HOME/Applications/$APP"
    echo "Installed to ~/Applications and launched."
fi
