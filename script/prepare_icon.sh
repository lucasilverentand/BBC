#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="$ROOT/build/AppIcon"
mkdir -p "$OUTPUT"
# Apple supplies the macOS mask, optical inset, edge and shadow.
xcrun actool "$ROOT/Assets/AppIcon.icon" \
  --compile "$OUTPUT" --platform macosx --minimum-deployment-target 26.0 \
  --app-icon AppIcon --output-partial-info-plist "$OUTPUT/Info.plist" \
  --output-format human-readable-text
