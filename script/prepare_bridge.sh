#!/usr/bin/env bash
set -euo pipefail
BBC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BBC_BRIDGE_BUILD="$BBC_ROOT/build/NativeBridge"
BBC_BRIDGE_SDK="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$BBC_BRIDGE_BUILD"
# Messages is a Mac Catalyst app; Apple Silicon builds use arm64e. A host
# macOS/arm64 library can be ignored at launch even when host checks pass.
for BBC_BRIDGE_ARCH in arm64 arm64e x86_64; do
  xcrun --sdk macosx clang -fobjc-arc -dynamiclib -O2 \
    -target "$BBC_BRIDGE_ARCH-apple-ios26.0-macabi" -isysroot "$BBC_BRIDGE_SDK" \
    -framework Foundation \
    "$BBC_ROOT/NativeBridge/NativeMessaging.m" "$BBC_ROOT/NativeBridge/EmbeddedSession.m" \
    -o "$BBC_BRIDGE_BUILD/BBCMessagesBridge-$BBC_BRIDGE_ARCH.dylib"
done
xcrun lipo -create \
  "$BBC_BRIDGE_BUILD/BBCMessagesBridge-arm64.dylib" \
  "$BBC_BRIDGE_BUILD/BBCMessagesBridge-arm64e.dylib" \
  "$BBC_BRIDGE_BUILD/BBCMessagesBridge-x86_64.dylib" \
  -output "$BBC_BRIDGE_BUILD/BBCMessagesBridge.dylib"
