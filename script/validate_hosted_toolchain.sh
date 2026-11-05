#!/usr/bin/env bash
# Unsigned compatibility evidence only. Never loads release credentials or launches the app.
set -euo pipefail
BBC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$BBC_ROOT"
BBC_EVIDENCE="$BBC_ROOT/build/toolchain-evidence"
mkdir -p "$BBC_EVIDENCE"
test "$(uname -m)" = arm64
/usr/bin/ruby script/ci_release_toolchain.rb > "$BBC_EVIDENCE/reviewed-toolchain.json"
export BBC_SYSTEM_SQLITE=1
export BBC_CONFIG=release
export BBC_ARCH=arm64
{
  git rev-parse HEAD
  xcodebuild -version
  swift --version
  xcrun --sdk macosx --show-sdk-version
  shasum -a 256 Assets/AppIcon.icon/icon.json
} > "$BBC_EVIDENCE/toolchain.txt"
python3 -m unittest discover -s script -p 'test_*.py'
/usr/bin/ruby script/test_release.rb
/usr/bin/ruby script/ci_release_test.rb
python3 script/test_swift.py . --configuration release --min-tests 25 --log build/test-logs/hosted-sdk.log
bash script/prepare_bridge.sh
for BBC_SLICE in arm64 arm64e x86_64; do
  xcrun lipo -verify_arch "$BBC_SLICE" build/NativeBridge/BBCMessagesBridge.dylib
  xcrun vtool -arch "$BBC_SLICE" -show-build build/NativeBridge/BBCMessagesBridge.dylib > "$BBC_EVIDENCE/bridge-$BBC_SLICE.txt"
  test "$(awk '$1 == "platform" {print $2}' "$BBC_EVIDENCE/bridge-$BBC_SLICE.txt")" = MACCATALYST
  test "$(awk '$1 == "minos" {print $2}' "$BBC_EVIDENCE/bridge-$BBC_SLICE.txt")" = 26.0
  xcrun nm -arch "$BBC_SLICE" -gU build/NativeBridge/BBCMessagesBridge.dylib > "$BBC_EVIDENCE/symbols-$BBC_SLICE.txt"
  for BBC_SYMBOL in BBCNativeCapabilities BBCNativePerform BBCNativePerformWithScanTimeout BBCNativePerformWithTimeouts BBCNativeDefaultLoadTimeout BBCNativeDefaultScanTimeout; do
    awk '{print $NF}' "$BBC_EVIDENCE/symbols-$BBC_SLICE.txt" | /usr/bin/grep -Fx "_$BBC_SYMBOL" >/dev/null
  done
done
python3 script/test_swift.py NativeBridge --configuration release --min-tests 34 --log build/test-logs/hosted-bridge.log
bash script/prepare_native.sh
git -C build/beeper-imessage rev-parse HEAD >> "$BBC_EVIDENCE/toolchain.txt"
python3 script/test_swift.py NativeMessages --configuration release --min-tests 169 --log build/test-logs/hosted-app.log
BBC_BINARY_DIR="$(swift build --package-path NativeMessages -c release --arch arm64 --show-bin-path)"
test "$(xcrun lipo -archs "$BBC_BINARY_DIR/BlueBubbleClub")" = arm64
xcrun vtool -show-build "$BBC_BINARY_DIR/BlueBubbleClub" > "$BBC_EVIDENCE/app-build.txt"
test "$(awk '$1 == "platform" {print $2}' "$BBC_EVIDENCE/app-build.txt")" = MACOS
test "$(awk '$1 == "minos" {print $2}' "$BBC_EVIDENCE/app-build.txt")" = 26.0
otool -L "$BBC_BINARY_DIR/BlueBubbleClub" > "$BBC_EVIDENCE/app-dependencies.txt"
if awk 'NR > 1 {print $1}' "$BBC_EVIDENCE/app-dependencies.txt" | /usr/bin/grep -E '/opt/homebrew|/usr/local|/Users/'; then
  echo 'Unsigned release links a machine-specific dependency' >&2
  exit 1
fi
cp "$BBC_BINARY_DIR/BlueBubbleClub" build/NativeBridge/BBCMessagesBridge.dylib "$BBC_EVIDENCE/"
# Keep the accepted Icon Composer source unchanged.
bash script/prepare_icon.sh
sips -s format png build/AppIcon/AppIcon.icns --out "$BBC_EVIDENCE/AppIcon.png" >/dev/null
# Compare these outputs with the local final Xcode 27.2 build before first signing.
cp build/AppIcon/Assets.car build/AppIcon/AppIcon.icns build/AppIcon/Info.plist "$BBC_EVIDENCE/"
find Assets/AppIcon.icon -type f -exec shasum -a 256 {} \; > "$BBC_EVIDENCE/icon-source-checksums.txt"
