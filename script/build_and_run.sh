#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="FileFoundry"
UPDATER_NAME="FileFoundryUpdater"
BUNDLE_ID="com.junowoz.filefoundry"
UPDATER_BUNDLE_ID="com.junowoz.filefoundry.updater"
VERSION="1.5.4"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_HELPERS="$APP_CONTENTS/Library/Helpers"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
UPDATER_BUNDLE="$APP_HELPERS/$UPDATER_NAME.app"
UPDATER_CONTENTS="$UPDATER_BUNDLE/Contents"
UPDATER_MACOS="$UPDATER_CONTENTS/MacOS"
UPDATER_BINARY="$UPDATER_MACOS/$UPDATER_NAME"
UPDATER_INFO_PLIST="$UPDATER_CONTENTS/Info.plist"
ICON_FILE="$ROOT_DIR/FileFoundryApp/Resources/FileFoundry.icns"
ENTITLEMENTS="$ROOT_DIR/FileFoundryApp/Resources/FileFoundry.entitlements"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

swift build --arch arm64 --product "$APP_NAME"
swift build --arch arm64 --product "$UPDATER_NAME"
BUILD_BINARY="$(swift build --arch arm64 --show-bin-path)/$APP_NAME"
UPDATER_BUILD_BINARY="$(swift build --arch arm64 --show-bin-path)/$UPDATER_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$UPDATER_MACOS"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$UPDATER_BUILD_BINARY" "$UPDATER_BINARY"
cp "$ICON_FILE" "$APP_RESOURCES/FileFoundry.icns"
chmod +x "$APP_BINARY"
chmod +x "$UPDATER_BINARY"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>FileFoundry</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSArchitecturePriority</key>
  <array>
    <string>arm64</string>
  </array>
  <key>NSMicrophoneUsageDescription</key>
  <string>File Foundry uses the microphone to record your voice in meetings you choose to transcribe.</string>
  <key>NSAudioCaptureUsageDescription</key>
  <string>File Foundry captures audio played by other apps when you record a meeting.</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>File Foundry captures the screen to record meetings and to stream the extended display to your tablet.</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>File Foundry finds your paired tablet on the local network for Second Screen.</string>
  <key>NSBonjourServices</key>
  <array>
    <string>_ffscreen._tcp</string>
  </array>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

cat >"$UPDATER_INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$UPDATER_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$UPDATER_BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>File Foundry Updater</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSArchitecturePriority</key>
  <array>
    <string>arm64</string>
  </array>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

# Bundled FFmpeg (scripts/build_ffmpeg.sh); without it the dev build falls back to Homebrew's.
if [[ -x "$ROOT_DIR/vendor/ffmpeg/bin/ffmpeg" ]]; then
  mkdir -p "$APP_CONTENTS/Helpers"
  for tool in ffmpeg ffprobe; do
    cp "$ROOT_DIR/vendor/ffmpeg/bin/$tool" "$APP_CONTENTS/Helpers/$tool"
    codesign --force --sign - --identifier "$BUNDLE_ID.$tool" "$APP_CONTENTS/Helpers/$tool" >/dev/null
  done
fi
codesign --force --sign - --identifier "$UPDATER_BUNDLE_ID" "$UPDATER_BUNDLE" >/dev/null
codesign --force --sign - --identifier "$BUNDLE_ID" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE" >/dev/null

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
