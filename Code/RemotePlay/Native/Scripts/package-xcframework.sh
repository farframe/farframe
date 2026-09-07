#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE="${TMPDIR:-/tmp}/RemotePlayNative"
DEVELOPER_DIR_PATH="${DEVELOPER_DIR:-$HOME/Downloads/Xcode.app/Contents/Developer}"
OUTPUT="$NATIVE_ROOT/../Packages/RemotePlayCore/Binaries/ChiakiNative.xcframework"

usage() {
    printf '%s\n' "Usage: $0 [--workspace PATH] [--developer-dir PATH] [--output PATH]"
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
        --output)
            OUTPUT="$2"
            shift 2
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

export DEVELOPER_DIR="$DEVELOPER_DIR_PATH"
actual_xcode="$(xcodebuild -version | tr '\n' ' ')"
case "$actual_xcode" in
    *"Xcode 26.6"*"17F113"*) ;;
    *)
        printf 'Expected Xcode 26.6 (17F113), found %s\n' "$actual_xcode" >&2
        exit 69
        ;;
esac

PRODUCTS="$WORKSPACE/products"
variants=(
    macos-arm64
    macos-x86_64
    xros-arm64
    xrsimulator-arm64
    iphoneos-arm64
    iphonesimulator-arm64
)

for variant in "${variants[@]}"; do
    product="$PRODUCTS/$variant"
    if [ ! -f "$product/libChiakiNative.a" ] || [ ! -d "$product/include" ]; then
        printf 'Missing native product for %s at %s\n' "$variant" "$product" >&2
        exit 66
    fi

    public_headers="$(find "$product/include" -type f -print | sed "s#^$product/include/##" | LC_ALL=C sort)"
    expected_headers="$(printf '%s\n' RemotePlayChiakiBridge.h module.modulemap | LC_ALL=C sort)"
    if [ "$public_headers" != "$expected_headers" ]; then
        printf 'Native product %s exposes unexpected public headers:\n%s\n' "$variant" "$public_headers" >&2
        exit 65
    fi
done

reference_headers="$PRODUCTS/macos-arm64/include"
for variant in "${variants[@]}"; do
    if ! diff -qr "$reference_headers" "$PRODUCTS/$variant/include" >/dev/null; then
        printf 'Public header mismatch for %s\n' "$variant" >&2
        diff -qr "$reference_headers" "$PRODUCTS/$variant/include" >&2
        exit 65
    fi
done

universal="$PRODUCTS/macos-universal"
rm -rf "$universal"
mkdir -p "$universal"
lipo -create \
    "$PRODUCTS/macos-arm64/libChiakiNative.a" \
    "$PRODUCTS/macos-x86_64/libChiakiNative.a" \
    -output "$universal/libChiakiNative.a"
/usr/bin/ditto "$reference_headers" "$universal/include"

mkdir -p "$(dirname "$OUTPUT")"
rm -rf "$OUTPUT"
xcodebuild -create-xcframework \
    -library "$PRODUCTS/xros-arm64/libChiakiNative.a" \
    -headers "$PRODUCTS/xros-arm64/include" \
    -library "$PRODUCTS/xrsimulator-arm64/libChiakiNative.a" \
    -headers "$PRODUCTS/xrsimulator-arm64/include" \
    -library "$PRODUCTS/iphoneos-arm64/libChiakiNative.a" \
    -headers "$PRODUCTS/iphoneos-arm64/include" \
    -library "$PRODUCTS/iphonesimulator-arm64/libChiakiNative.a" \
    -headers "$PRODUCTS/iphonesimulator-arm64/include" \
    -library "$universal/libChiakiNative.a" \
    -headers "$universal/include" \
    -output "$OUTPUT"

plutil -lint "$OUTPUT/Info.plist" >/dev/null
plist="$(plutil -p "$OUTPUT/Info.plist")"
for identifier in ios-arm64 ios-arm64-simulator xros-arm64 xros-arm64-simulator macos-arm64_x86_64; do
    needle="\"LibraryIdentifier\" => \"$identifier\""
    case "$plist" in
        *"$needle"*) ;;
        *)
            printf 'XCFramework is missing slice %s\n' "$identifier" >&2
            exit 65
            ;;
    esac
done

checksum_file="$(dirname "$OUTPUT")/ChiakiNative.sha256"
find "$OUTPUT" -type f -name '*.a' | LC_ALL=C sort | while IFS= read -r library; do
    shasum -a 256 "$library"
done > "$checksum_file"

printf 'XCFRAMEWORK VERIFIED  %s\n' "$OUTPUT"
printf 'XCFRAMEWORK VERIFIED  checksums: %s\n' "$checksum_file"
