#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Use writable caches without changing HOME. Optional for unrestricted developer machines.
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/connectionrig-clang}"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mode="${1:-all}"
set --
if [ "${RIG_DISABLE_BUILD_SANDBOX:-0}" = 1 ]; then set -- --disable-sandbox; fi
if [ -n "${RIG_SCRATCH_PATH:-}" ]; then set -- "$@" --scratch-path "$RIG_SCRATCH_PATH"; fi
if [ "$mode" = unit ]; then
    swift test "$@" --disable-xctest --skip 'liveTransfer|sdkUnavailable|directionalUpload'
else
    swift test "$@" --disable-xctest
fi
