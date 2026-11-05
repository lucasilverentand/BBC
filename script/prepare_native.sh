#!/usr/bin/env bash
set -euo pipefail
BBC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BBC_REV=07d8d04f7145e0606df48e405f5c0be28aa207de
BBC_SOURCE="$BBC_ROOT/build/beeper-imessage"
BBC_CONFIG="${BBC_CONFIG:-debug}"
case "$BBC_CONFIG" in debug|release) ;; *) echo 'BBC_CONFIG must be debug or release' >&2; exit 2 ;; esac
mkdir -p "$BBC_ROOT/build"
if [[ ! -d "$BBC_SOURCE/.git" ]]; then
  git clone --quiet https://github.com/beeper/platform-imessage.git "$BBC_SOURCE"
fi
# This directory is a disposable, ignored build dependency, never a user checkout.
[[ "$(git -C "$BBC_SOURCE" remote get-url origin)" == https://github.com/beeper/platform-imessage.git ]]
git -C "$BBC_SOURCE" checkout --quiet --detach "$BBC_REV"
git -C "$BBC_SOURCE" diff --quiet || git -C "$BBC_SOURCE" apply --reverse --check "$BBC_ROOT/NativeMessages/beeper-bbc.patch"
if git -C "$BBC_SOURCE" diff --quiet; then git -C "$BBC_SOURCE" apply "$BBC_ROOT/NativeMessages/beeper-bbc.patch"; fi
# Reject any build-cache modification outside the exact reviewed patch.
[[ "$(git -C "$BBC_SOURCE" diff)" == "$(cat "$BBC_ROOT/NativeMessages/beeper-bbc.patch")" ]]
# Pin all transitive versions in BBC's dedicated lockfile.
BBC_BUILD_COMMAND=(swift build --jobs "${BBC_BUILD_JOBS:-2}" --disable-automatic-resolution --package-path "$BBC_ROOT/NativeMessages" --product BlueBubbleClub -c "$BBC_CONFIG")
if [[ -n "${BBC_ARCH:-}" ]]; then BBC_BUILD_COMMAND+=(--arch "$BBC_ARCH"); fi
"${BBC_BUILD_COMMAND[@]}"
