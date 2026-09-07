#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${TMPDIR:-/tmp}/RemotePlayNative"
DEVELOPER_DIR_PATH="${DEVELOPER_DIR:-$HOME/Downloads/Xcode.app/Contents/Developer}"
OFFLINE=0

usage() {
    printf '%s\n' "Usage: $0 [--workspace PATH] [--developer-dir PATH] [--offline]"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --workspace)
            WORKSPACE="$2"
            shift 2
            ;;
        --developer-dir)
            DEVELOPER_DIR_PATH="$2"
            shift 2
            ;;
        --offline)
            OFFLINE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 64
            ;;
    esac
done

"$SCRIPT_DIR/verify-source-lock.sh"
fetch_args=(--workspace "$WORKSPACE")
if [ "$OFFLINE" -eq 1 ]; then
    fetch_args+=(--offline)
fi
"$SCRIPT_DIR/fetch-sources.sh" "${fetch_args[@]}"

variants=(
    macos-arm64
    macos-x86_64
    xros-arm64
    xrsimulator-arm64
    iphoneos-arm64
    iphonesimulator-arm64
)
for variant in "${variants[@]}"; do
    "$SCRIPT_DIR/build-variant.sh" \
        --variant "$variant" \
        --workspace "$WORKSPACE" \
        --developer-dir "$DEVELOPER_DIR_PATH"
done

"$SCRIPT_DIR/verify-abi.sh" \
    --workspace "$WORKSPACE" \
    --developer-dir "$DEVELOPER_DIR_PATH"
"$SCRIPT_DIR/package-xcframework.sh" \
    --workspace "$WORKSPACE" \
    --developer-dir "$DEVELOPER_DIR_PATH"

printf 'NATIVE PIPELINE VERIFIED  Xcode 26.6 / Apple OS 26.0\n'
