#!/bin/bash
# Isolated, credential-free diagnostic. Never modifies or replaces an XCFramework.
set -euo pipefail
native_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    printf 'Usage: %s [--candidate-library PATH] RECONSTRUCTED_NATIVE_WORKSPACE OUTPUT_DIRECTORY [HTTPS_PROBE_URL]\n' "$0" >&2
}

candidate_library=""
args=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --candidate-library)
            if [ "$#" -lt 2 ] || [ -z "$2" ]; then
                printf -- '--candidate-library requires a non-empty path\n' >&2
                exit 64
            fi
            candidate_library="$2"
            shift 2
            ;;
        -*)
            usage
            exit 64
            ;;
        *)
            args+=("$1")
            shift
            ;;
    esac
done
if [ "${#args[@]}" -lt 2 ] || [ "${#args[@]}" -gt 3 ]; then
    usage
    exit 64
fi
workspace="${args[0]}"
output="${args[1]}"
https_url=""
if [ "${#args[@]}" -eq 3 ]; then
    https_url="${args[2]}"
fi

if [ -n "$candidate_library" ]; then
    if [ ! -f "$candidate_library" ]; then
        printf 'Candidate library not found: %s\n' "$candidate_library" >&2
        exit 66
    fi
    library="$candidate_library"
else
    library="$native_root/../Packages/RemotePlayCore/Binaries/ChiakiNative.xcframework/macos-arm64_x86_64/libChiakiNative.a"
    if [ ! -f "$library" ]; then
        printf 'Packaged native library not found: %s\n' "$library" >&2
        exit 66
    fi
fi
library="$(cd "$(dirname "$library")" && pwd)/$(basename "$library")"

mkdir -p "$output"
"$native_root/Scripts/verify-source-lock.sh" > "$output/source-lock.log"
{
    printf 'library %s\n' "$library"
    shasum -a 256 "$library"
} | tee "$output/library.sha256"
xcrun clang -arch arm64 -DCHIAKI_LIB_ENABLE_MBEDTLS \
    -I"$workspace/sources/chiaki-ng/lib/include" \
    -I"$workspace/sources/dependencies/mbedtls/include" \
    -I"$workspace/sources/chiaki-ng/third-party/curl/include" \
    "$native_root/Tests/away_security_probe.c" "$library" \
    -framework Security -framework CoreFoundation -framework SystemConfiguration -framework CoreServices -lz \
    -o "$output/native-security-probe"
signature_failed=0
tls_failed=0
"$output/native-security-probe" > "$output/handshake.log" 2>&1 || signature_failed=1
cat "$output/handshake.log"
if [ -n "$https_url" ]; then
    {
        printf 'TLS PROOF (not Away-ready)\n'
        "$output/native-security-probe" trust "$https_url"
    } > "$output/trust.log" 2>&1 || tls_failed=1
    cat "$output/trust.log"
fi
if [ "$signature_failed" -ne 0 ] || [ "$tls_failed" -ne 0 ]; then
    if [ "$signature_failed" -eq 0 ]; then
        signature_status=pass
    else
        signature_status=fail
    fi
    if [ -z "$https_url" ]; then
        tls_status=skipped
    elif [ "$tls_failed" -eq 0 ]; then
        tls_status=pass
    else
        tls_status=fail
    fi
    printf 'AWAY SECURITY GATE NOT CLEARED. signature=%s tls-proof=%s. See the diagnostic logs; no complete-session exploit is inferred.\n' \
        "$signature_status" "$tls_status" >&2
    exit 1
fi
printf 'PROBE PASSED. Signature and TLS proof are not Away-ready, protocol, provider, device or release acceptance.\n'
