#!/bin/sh
# Creates a local development bundle. Does not launch, publish, notarize, or install it.
set -eu
cd "$(dirname "$0")/.."
set --
if [ "${RIG_DISABLE_BUILD_SANDBOX:-0}" = 1 ]; then set -- --disable-sandbox; fi
if [ -n "${RIG_SCRATCH_PATH:-}" ]; then set -- "$@" --scratch-path "$RIG_SCRATCH_PATH"; fi
swift build "$@" --product RigCompanion
binary_dir=$(swift build "$@" --show-bin-path)
bundle=dist/ConnectionRig.app
mkdir -p "$bundle/Contents/MacOS"
cp "$binary_dir/RigCompanion" "$bundle/Contents/MacOS/RigCompanion"
cp packaging/Companion-Info.plist "$bundle/Contents/Info.plist"
codesign --force --sign - "$bundle"
printf 'Created %s\n' "$bundle"
