#!/bin/bash
# Isolated, credential-free diagnostic. Never modifies or replaces an XCFramework.
set -euo pipefail
native_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    printf 'Usage: %s RECONSTRUCTED_NATIVE_WORKSPACE OUTPUT_DIRECTORY [HTTPS_PROBE_URL]\n' "$0" >&2
    exit 64
fi
workspace="$1"
output="$2"
mkdir -p "$output"
library="$native_root/../Packages/RemotePlayCore/Binaries/ChiakiNative.xcframework/macos-arm64_x86_64/libChiakiNative.a"
"$native_root/Scripts/verify-source-lock.sh" > "$output/source-lock.log"
shasum -a 256 "$library" > "$output/library.sha256"
xcrun clang -arch arm64 -DCHIAKI_LIB_ENABLE_MBEDTLS \
    -I"$workspace/sources/chiaki-ng/lib/include" \
    -I"$workspace/sources/dependencies/mbedtls/include" \
    -I"$workspace/sources/chiaki-ng/third-party/curl/include" \
    "$native_root/Tests/away_security_probe.c" "$library" \
    -framework Security -framework CoreFoundation -framework SystemConfiguration -framework CoreServices -lz \
    -o "$output/native-security-probe"
failed=0
"$output/native-security-probe" > "$output/handshake.log" 2>&1 || failed=1
cat "$output/handshake.log"
if [ "$#" -eq 3 ]; then
    "$output/native-security-probe" trust "$3" > "$output/trust.log" 2>&1 || failed=1
    cat "$output/trust.log"
fi
if [ "$failed" -ne 0 ]; then
    printf 'AWAY SECURITY GATE NOT CLEARED. See the diagnostic logs; no complete-session exploit is inferred.\n' >&2
    exit 1
fi
printf 'PROBE PASSED. This is not full protocol, provider, device or release acceptance.\n'
