#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCK_FILE="$NATIVE_ROOT/Manifest/sources.lock"
WORKSPACE="${TMPDIR:-/tmp}/RemotePlayNative"
CACHE_DIR="$HOME/Library/Caches/com.unshackledpursuit.remoteplay/native-sources"
OFFLINE=0

usage() {
    printf '%s\n' "Usage: $0 [--workspace PATH] [--cache PATH] [--offline]"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --workspace)
            WORKSPACE="$2"
            shift 2
            ;;
        --cache)
            CACHE_DIR="$2"
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

mkdir -p "$CACHE_DIR"
rm -rf "$WORKSPACE/sources"
mkdir -p "$WORKSPACE/sources"

verify_sha256() {
    local path="$1"
    local expected="$2"
    local actual
    actual="$(shasum -a 256 "$path" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
        printf 'SHA-256 mismatch for %s\nexpected %s\nactual   %s\n' "$path" "$expected" "$actual" >&2
        return 1
    fi
}

while IFS=$'\t' read -r name filename destination url expected_sha revision license; do
    case "$name" in
        ''|'#'*) continue ;;
    esac

    archive="$CACHE_DIR/$filename"
    if [ ! -f "$archive" ]; then
        if [ "$OFFLINE" -eq 1 ]; then
            printf 'Missing offline source: %s\n' "$archive" >&2
            exit 66
        fi
        temporary="$archive.partial"
        rm -f "$temporary"
        curl -L --fail --retry 3 "$url" -o "$temporary"
        verify_sha256 "$temporary" "$expected_sha"
        mv "$temporary" "$archive"
    fi

    verify_sha256 "$archive" "$expected_sha"
    target="$WORKSPACE/sources/$destination"
    rm -rf "$target"
    mkdir -p "$target"
    tar -xzf "$archive" -C "$target" --strip-components=1
    printf 'SOURCE VERIFIED  %-14s %s\n' "$name" "$revision"
done < "$LOCK_FILE"

CHIAKI_SOURCE="$WORKSPACE/sources/chiaki-ng"
CURL_SOURCE="$CHIAKI_SOURCE/third-party/curl"

(
    cd "$CURL_SOURCE"
    git apply --no-index "$NATIVE_ROOT/Patches/known-good-chiaki-curl-6b06124.patch"
)

(
    cd "$CHIAKI_SOURCE"
    git apply --no-index --exclude=third-party/curl "$NATIVE_ROOT/Patches/known-good-chiaki-ng-6b06124.patch"
    git apply --no-index "$NATIVE_ROOT/Patches/chiaki-ng-registration-no-sigpipe-2026-07-15.patch"
    git apply --no-index "$NATIVE_ROOT/Patches/chiaki-ng-local-only-holepunch-2026-08-29.patch"
)

grep -q 'chiaki_session_runtime_size' "$CHIAKI_SOURCE/lib/src/session.c"
grep -q 'TAKION_SOCKET_RCVBUF' "$CHIAKI_SOURCE/lib/src/takion.c"
grep -q 'setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE' "$CHIAKI_SOURCE/lib/src/regist.c"
grep -q 'src/remote/holepunch-disabled.c' "$CHIAKI_SOURCE/lib/CMakeLists.txt"
grep -q 'return CHIAKI_ERR_UNINITIALIZED;' "$CHIAKI_SOURCE/lib/src/remote/holepunch-disabled.c"
grep -q 'if(FALSE AND APPLE AND NOT ENABLE_ARES)' "$CURL_SOURCE/CMakeLists.txt"

patch_manifest="$WORKSPACE/source-state.sha256"
(
    cd "$NATIVE_ROOT"
    shasum -a 256 \
        Patches/known-good-chiaki-curl-6b06124.patch \
        Patches/known-good-chiaki-ng-6b06124.patch \
        Patches/chiaki-ng-registration-no-sigpipe-2026-07-15.patch \
        Patches/chiaki-ng-local-only-holepunch-2026-08-29.patch
) > "$patch_manifest"

printf 'SOURCE VERIFIED  patched source tree: %s\n' "$WORKSPACE/sources"
printf 'SOURCE VERIFIED  patch manifest: %s\n' "$patch_manifest"
