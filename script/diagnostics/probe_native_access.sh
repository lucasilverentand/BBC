#!/usr/bin/env bash
set -euo pipefail
BBC_PROBE_SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
umask 077
BBC_PROBE_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/bbc-native-access.XXXXXX")"
trap 'rm -rf "$BBC_PROBE_TEMP"' EXIT
BBC_PROBE_APP="$BBC_PROBE_TEMP/BBCNativeAccessProbe.app"
mkdir -p "$BBC_PROBE_APP/Contents/MacOS"
cat > "$BBC_PROBE_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>club.bluebubble.native-access-probe</string>
  <key>CFBundleExecutable</key><string>BBCNativeAccessProbe</string>
  <key>CFBundleName</key><string>BBC Native Access Probe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
xcrun clang -fobjc-arc -framework Foundation "$BBC_PROBE_SOURCE/NativeAccessProbe.m" \
  -o "$BBC_PROBE_APP/Contents/MacOS/BBCNativeAccessProbe"
codesign --force --sign "${BBC_SIGNING_IDENTITY:--}" --options runtime "$BBC_PROBE_APP"
"$BBC_PROBE_APP/Contents/MacOS/BBCNativeAccessProbe" "$@"
