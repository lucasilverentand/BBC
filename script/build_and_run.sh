#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-run}"
APP_NAME=BlueBubbleClub
BUNDLE="$ROOT/dist/Blue Bubble Club.app"
# Machine-specific signing selection stays outside the repository.
if [[ -f "$ROOT/Config/LocalSigning.env" ]]; then source "$ROOT/Config/LocalSigning.env"; fi
if [[ -z "${BBC_SIGNING_IDENTITY:-}" ]]; then
  BBC_SIGNING_IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)"/\1/p' | head -1)"
fi
[[ -n "$BBC_SIGNING_IDENTITY" ]] || { echo 'Set BBC_SIGNING_IDENTITY to a valid Apple Development identity.' >&2; exit 1; }
if [[ "$MODE" != build ]]; then pkill -x "$APP_NAME" >/dev/null 2>&1 || true; fi
bash "$ROOT/script/prepare_native.sh"
BIN="$(swift build --package-path "$ROOT/NativeMessages" --show-bin-path)"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN/$APP_NAME" "$BUNDLE/Contents/MacOS/$APP_NAME"
for RESOURCE in BBCMessagesActions_BBCMessagesActions FluidAudio_FluidAudio; do
  [[ -d "$BIN/$RESOURCE.bundle" ]] || { echo "Missing $RESOURCE.bundle" >&2; exit 1; }
  rm -rf "$BUNDLE/Contents/Resources/$RESOURCE.bundle"
  cp -R "$BIN/$RESOURCE.bundle" "$BUNDLE/Contents/Resources/"
  codesign --force --sign "$BBC_SIGNING_IDENTITY" "$BUNDLE/Contents/Resources/$RESOURCE.bundle"
done
cp -R "$ROOT/LICENSES" "$BUNDLE/Contents/Resources/"
cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$BUNDLE/Contents/Resources/"
cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>BlueBubbleClub</string>
<key>CFBundleIdentifier</key><string>club.bluebubble.app</string>
<key>CFBundleName</key><string>Blue Bubble Club</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSAppleEventsUsageDescription</key><string>Blue Bubble Club sends messages through your local Messages account when an authorized API client requests it.</string>
</dict></plist>
PLIST
codesign --force --sign "$BBC_SIGNING_IDENTITY" --options runtime --entitlements "$ROOT/Config/BBCMessagesActions.entitlements" "$BUNDLE"
codesign --verify --strict --deep "$BUNDLE"
case "$MODE" in
  build) echo "$BUNDLE" ;;
  run) /usr/bin/open -n "$BUNDLE" ;;
  --debug) lldb -- "$BUNDLE/Contents/MacOS/$APP_NAME" ;;
  --logs) /usr/bin/open -n "$BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "BlueBubbleClub"' ;;
  --telemetry) /usr/bin/open -n "$BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "club.bluebubble.transport"' ;;
  --verify) /usr/bin/open -n "$BUNDLE"; sleep 1; pgrep -x "$APP_NAME" >/dev/null ;;
  *) echo 'Usage: script/build_and_run.sh [run|build|--debug|--logs|--telemetry|--verify]' >&2; exit 2 ;;
esac
