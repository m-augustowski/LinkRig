#!/bin/sh
# Use the Swift toolchain formatter and the repository's checked-in configuration.
set -eu
cd "$(dirname "$0")/.."

case "${1:-check}" in
    check)
        xcrun swift-format lint --strict --recursive Package.swift Sources Tests Examples
        ;;
    fix)
        xcrun swift-format format --in-place --recursive Package.swift Sources Tests Examples
        ;;
    *)
        printf 'Usage: sh scripts/format.sh [check|fix]\n' >&2
        exit 2
        ;;
esac
