#!/usr/bin/env bash
set -euo pipefail
BBC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$BBC_ROOT/build/NativeBridge"
clang -fobjc-arc -dynamiclib -mmacosx-version-min=26.0 -O2 \
  -framework Foundation \
  "$BBC_ROOT/NativeBridge/NativeMessaging.m" "$BBC_ROOT/NativeBridge/EmbeddedSession.m" \
  -o "$BBC_ROOT/build/NativeBridge/BBCMessagesBridge.dylib"
