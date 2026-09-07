#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE="${TMPDIR:-/tmp}/RemotePlayNative"
DEVELOPER_DIR_PATH="${DEVELOPER_DIR:-$HOME/Downloads/Xcode.app/Contents/Developer}"
VARIANT=""

usage() {
    printf '%s\n' "Usage: $0 --variant NAME [--workspace PATH] [--developer-dir PATH]"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --variant)
            VARIANT="$2"
            shift 2
            ;;
        --workspace)
            WORKSPACE="$2"
            shift 2
            ;;
        --developer-dir)
            DEVELOPER_DIR_PATH="$2"
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

case "$VARIANT" in
    xros-arm64)
        SYSTEM_NAME=visionOS; SDK=xros; ARCH=arm64; TARGET_TRIPLE=arm64-apple-xros26.0 ;;
    xrsimulator-arm64)
        SYSTEM_NAME=visionOS; SDK=xrsimulator; ARCH=arm64; TARGET_TRIPLE=arm64-apple-xros26.0-simulator ;;
    iphoneos-arm64)
        SYSTEM_NAME=iOS; SDK=iphoneos; ARCH=arm64; TARGET_TRIPLE=arm64-apple-ios26.0 ;;
    iphonesimulator-arm64)
        SYSTEM_NAME=iOS; SDK=iphonesimulator; ARCH=arm64; TARGET_TRIPLE=arm64-apple-ios26.0-simulator ;;
    macos-arm64)
        SYSTEM_NAME=Darwin; SDK=macosx; ARCH=arm64; TARGET_TRIPLE=arm64-apple-macos26.0 ;;
    macos-x86_64)
        SYSTEM_NAME=Darwin; SDK=macosx; ARCH=x86_64; TARGET_TRIPLE=x86_64-apple-macos26.0 ;;
    *)
        usage >&2
        exit 64 ;;
esac

export DEVELOPER_DIR="$DEVELOPER_DIR_PATH"
MIN_OS=26.0
SOURCES="$WORKSPACE/sources"
VARIANT_ROOT="$WORKSPACE/build/$VARIANT"
PREFIX="$VARIANT_ROOT/prefix"
OUTPUT="$WORKSPACE/products/$VARIANT"
JOBS="${RP_BUILD_JOBS:-$(sysctl -n hw.ncpu)}"

case "$JOBS" in
    ''|*[!0-9]*)
        printf 'RP_BUILD_JOBS must be a positive integer, found %s\n' "$JOBS" >&2
        exit 64
        ;;
esac
if [ "$JOBS" -eq 0 ]; then
    printf 'RP_BUILD_JOBS must be greater than zero.\n' >&2
    exit 64
fi

if [ ! -f "$SOURCES/chiaki-ng/CMakeLists.txt" ]; then
    printf 'Missing reconstructed sources at %s; run fetch-sources.sh first.\n' "$SOURCES" >&2
    exit 66
fi

actual_xcode="$(xcodebuild -version | tr '\n' ' ')"
case "$actual_xcode" in
    *"Xcode 26.6"*"17F113"*) ;;
    *)
        printf 'Expected Xcode 26.6 (17F113), found %s\n' "$actual_xcode" >&2
        exit 69 ;;
esac

rm -rf "$VARIANT_ROOT" "$OUTPUT"
mkdir -p "$PREFIX" "$OUTPUT/include"

COMMON_CMAKE_ARGS=(
    -G Ninja
    -DCMAKE_TOOLCHAIN_FILE="$NATIVE_ROOT/CMake/AppleCross.cmake"
    -DRP_SYSTEM_NAME="$SYSTEM_NAME"
    -DRP_SDK="$SDK"
    -DRP_ARCH="$ARCH"
    -DRP_MIN_OS="$MIN_OS"
    -DRP_TARGET_TRIPLE="$TARGET_TRIPLE"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="$PREFIX"
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
)

build_and_install() {
    local name="$1"
    local source="$2"
    shift 2
    local build="$VARIANT_ROOT/$name"
    cmake -S "$source" -B "$build" "${COMMON_CMAKE_ARGS[@]}" "$@"
    cmake --build "$build" --parallel "$JOBS"
    cmake --install "$build"
}

build_and_install mbedtls "$SOURCES/dependencies/mbedtls" \
    -DENABLE_PROGRAMS=OFF \
    -DENABLE_TESTING=OFF \
    -DUSE_SHARED_MBEDTLS_LIBRARY=OFF \
    -DUSE_STATIC_MBEDTLS_LIBRARY=ON \
    -DMBEDTLS_FATAL_WARNINGS=OFF

build_and_install json-c "$SOURCES/dependencies/json-c" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_STATIC_LIBS=ON \
    -DBUILD_APPS=OFF \
    -DBUILD_TESTING=OFF \
    -DDISABLE_WERROR=ON

build_and_install miniupnpc "$SOURCES/dependencies/miniupnpc" \
    -DUPNPC_BUILD_SHARED=OFF \
    -DUPNPC_BUILD_STATIC=ON \
    -DUPNPC_BUILD_TESTS=OFF \
    -DUPNPC_BUILD_SAMPLE=OFF

build_and_install opus "$SOURCES/dependencies/opus" \
    -DBUILD_SHARED_LIBS=OFF \
    -DOPUS_BUILD_TESTING=OFF \
    -DOPUS_BUILD_PROGRAMS=OFF

export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR=""

CHIAKI_BUILD="$VARIANT_ROOT/chiaki-ng"
cmake -S "$SOURCES/chiaki-ng" -B "$CHIAKI_BUILD" \
    "${COMMON_CMAKE_ARGS[@]}" \
    -DCMAKE_PREFIX_PATH="$PREFIX" \
    -DCMAKE_FIND_ROOT_PATH="$PREFIX" \
    -DCHIAKI_ENABLE_TESTS=OFF \
    -DCHIAKI_ENABLE_CLI=OFF \
    -DCHIAKI_ENABLE_GUI=OFF \
    -DCHIAKI_ENABLE_ANDROID=OFF \
    -DCHIAKI_ENABLE_BOREALIS=OFF \
    -DCHIAKI_ENABLE_SETSU=OFF \
    -DCHIAKI_ENABLE_STEAMDECK_NATIVE=OFF \
    -DCHIAKI_ENABLE_FFMPEG_DECODER=OFF \
    -DCHIAKI_ENABLE_PI_DECODER=OFF \
    -DCHIAKI_ENABLE_SPEEX=OFF \
    -DCHIAKI_ENABLE_STEAM_SHORTCUT=OFF \
    -DCHIAKI_ENABLE_RUDP=OFF \
    -DCHIAKI_LIB_ENABLE_OPUS=ON \
    -DCHIAKI_LIB_ENABLE_MBEDTLS=ON \
    -DCHIAKI_LIB_MBEDTLS_EXTERNAL_PROJECT=OFF \
    -DCHIAKI_USE_SYSTEM_JERASURE=OFF \
    -DCHIAKI_USE_SYSTEM_NANOPB=OFF \
    -DCHIAKI_USE_SYSTEM_CURL=OFF \
    -DMBEDTLS="$PREFIX/lib/libmbedtls.a" \
    -DMBEDX509="$PREFIX/lib/libmbedx509.a" \
    -DMBEDCRYPTO="$PREFIX/lib/libmbedcrypto.a" \
    -DOpus_INCLUDE_DIRS="$PREFIX/include/opus" \
    -DOpus_LIBRARIES="$PREFIX/lib/libopus.a" \
    -DCURL_USE_SECTRANSP=OFF \
    -DCURL_USE_OPENSSL=OFF \
    -DCURL_USE_MBEDTLS=ON \
    -DMBEDTLS_INCLUDE_DIR="$PREFIX/include" \
    -DMBEDTLS_LIBRARY="$PREFIX/lib/libmbedtls.a" \
    -DMBEDX509_LIBRARY="$PREFIX/lib/libmbedx509.a" \
    -DMBEDCRYPTO_LIBRARY="$PREFIX/lib/libmbedcrypto.a" \
    -DBUILD_SHARED_LIBS=OFF

cmake --build "$CHIAKI_BUILD" --target chiaki-lib --parallel "$JOBS"

cp -R "$SOURCES/chiaki-ng/lib/include/chiaki" "$OUTPUT/include/"
cp "$CHIAKI_BUILD/lib/include/chiaki/config.h" "$OUTPUT/include/chiaki/config.h"
cp "$NATIVE_ROOT/Sources/ChiakiNativeBridge/include/RemotePlayChiakiBridge.h" "$OUTPUT/include/"
cp "$NATIVE_ROOT/Sources/ChiakiNativeBridge/include/module.modulemap" "$OUTPUT/include/"

SDK_PATH="$(xcrun --sdk "$SDK" --show-sdk-path)"
CLANG="$(xcrun --sdk "$SDK" --find clang)"
BRIDGE_OBJECT="$VARIANT_ROOT/RemotePlayChiakiBridge.o"
"$CLANG" -c "$NATIVE_ROOT/Sources/ChiakiNativeBridge/RemotePlayChiakiBridge.c" \
    -target "$TARGET_TRIPLE" \
    -isysroot "$SDK_PATH" \
    -I"$OUTPUT/include" \
    -I"$PREFIX/include" \
    -O2 \
    -o "$BRIDGE_OBJECT"

BRIDGE_LIBRARY="$VARIANT_ROOT/libRemotePlayChiakiBridge.a"
ar -rcs "$BRIDGE_LIBRARY" "$BRIDGE_OBJECT"

libraries=(
    "$CHIAKI_BUILD/lib/libchiaki.a"
    "$CHIAKI_BUILD/third-party/curl/lib/libcurl.a"
    "$CHIAKI_BUILD/third-party/libgf_complete.a"
    "$CHIAKI_BUILD/third-party/libjerasure.a"
    "$CHIAKI_BUILD/third-party/nanopb/libprotobuf-nanopb.a"
    "$PREFIX/lib/libjson-c.a"
    "$PREFIX/lib/libminiupnpc.a"
    "$PREFIX/lib/libopus.a"
    "$PREFIX/lib/libmbedtls.a"
    "$PREFIX/lib/libmbedx509.a"
    "$PREFIX/lib/libmbedcrypto.a"
    "$BRIDGE_LIBRARY"
)

for library in "${libraries[@]}"; do
    if [ ! -f "$library" ]; then
        printf 'Missing expected library: %s\n' "$library" >&2
        exit 70
    fi
done

/usr/bin/libtool -static -o "$OUTPUT/libChiakiNative.a" "${libraries[@]}"
rm -rf "$OUTPUT/include/chiaki"
shasum -a 256 "$OUTPUT/libChiakiNative.a" > "$OUTPUT/libChiakiNative.sha256"

printf 'BUILD VERIFIED  %s -> %s\n' "$VARIANT" "$OUTPUT/libChiakiNative.a"
