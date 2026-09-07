#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE="${TMPDIR:-/tmp}/RemotePlayNative"
DEVELOPER_DIR_PATH="${DEVELOPER_DIR:-$HOME/Downloads/Xcode.app/Contents/Developer}"

usage() {
    printf '%s\n' "Usage: $0 [--workspace PATH] [--developer-dir PATH]"
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
product="$WORKSPACE/products/macos-arm64"
library="$product/libChiakiNative.a"
headers="$product/include"
if [ ! -f "$library" ] || [ ! -d "$headers" ]; then
    printf 'Missing macos-arm64 native product at %s\n' "$product" >&2
    exit 66
fi

expected_abi="$(sed -n 's/^#define RP_CHIAKI_NATIVE_ABI_VERSION \([0-9][0-9]*\)u$/\1/p' "$headers/RemotePlayChiakiBridge.h")"
if [ -z "$expected_abi" ]; then
    printf 'Unable to determine native ABI version from %s\n' "$headers/RemotePlayChiakiBridge.h" >&2
    exit 65
fi

verification="$WORKSPACE/verification/macos-arm64"
rm -rf "$verification"
mkdir -p "$verification"
binary="$verification/abi_smoke"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
clang="$(xcrun --sdk macosx --find clang)"

"$clang" \
    -target arm64-apple-macos26.0 \
    -isysroot "$sdk_path" \
    -I"$headers" \
    "$NATIVE_ROOT/Tests/abi_smoke.c" \
    "$library" \
    -lz \
    -framework CoreServices \
    -framework Security \
    -framework SystemConfiguration \
    -framework CoreFoundation \
    -o "$binary"

abi_output="$("$binary")"
case "$abi_output" in
    "ChiakiNative ABI $expected_abi "*) ;;
    *)
        printf 'Unexpected ABI smoke output: %s\n' "$abi_output" >&2
        exit 65
        ;;
esac

build_info="$(vtool -show-build "$binary")"
case "$build_info" in
    *"platform MACOS"*"minos 26.0"*) ;;
    *)
        printf 'ABI smoke executable has an unexpected platform/minimum OS:\n%s\n' "$build_info" >&2
        exit 65
        ;;
esac

wake_parser_binary="$verification/wake_parser_contract"
"$clang" \
    -std=c11 \
    -Wall \
    -Wextra \
    -Werror \
    -target arm64-apple-macos26.0 \
    -isysroot "$sdk_path" \
    -I"$NATIVE_ROOT/Tests/Fakes" \
    -I"$NATIVE_ROOT/Sources/ChiakiNativeBridge/include" \
    "$NATIVE_ROOT/Sources/ChiakiNativeBridge/RemotePlayChiakiBridge.c" \
    "$NATIVE_ROOT/Tests/Fakes/fake_chiaki_runtime.c" \
    "$NATIVE_ROOT/Tests/wake_parser_contract.c" \
    -o "$wake_parser_binary"

wake_parser_output="$("$wake_parser_binary")"
if [ "$wake_parser_output" != "WAKE PARSER VERIFIED  1-8 hex digits, fail-closed, fake transport only" ]; then
    printf 'Unexpected Wake parser contract output: %s\n' "$wake_parser_output" >&2
    exit 65
fi

wake_parser_build_info="$(vtool -show-build "$wake_parser_binary")"
case "$wake_parser_build_info" in
    *"platform MACOS"*"minos 26.0"*) ;;
    *)
        printf 'Wake parser contract executable has an unexpected platform/minimum OS:\n%s\n' "$wake_parser_build_info" >&2
        exit 65
        ;;
esac

session_bridge_binary="$verification/session_bridge_contract"
"$clang" \
    -std=c11 \
    -Wall \
    -Wextra \
    -Werror \
    -target arm64-apple-macos26.0 \
    -isysroot "$sdk_path" \
    -I"$NATIVE_ROOT/Tests/Fakes" \
    -I"$NATIVE_ROOT/Sources/ChiakiNativeBridge/include" \
    "$NATIVE_ROOT/Sources/ChiakiNativeBridge/RemotePlayChiakiBridge.c" \
    "$NATIVE_ROOT/Tests/Fakes/fake_chiaki_runtime.c" \
    "$NATIVE_ROOT/Tests/session_bridge_contract.c" \
    -o "$session_bridge_binary"

session_bridge_output="$("$session_bridge_binary")"
if [ "$session_bridge_output" != "SESSION BRIDGE VERIFIED  exact PS5 media/control callbacks, isolation, retry-safe lifecycle" ]; then
    printf 'Unexpected session bridge contract output: %s\n' "$session_bridge_output" >&2
    exit 65
fi

session_bridge_build_info="$(vtool -show-build "$session_bridge_binary")"
case "$session_bridge_build_info" in
    *"platform MACOS"*"minos 26.0"*) ;;
    *)
        printf 'Session bridge contract executable has an unexpected platform/minimum OS:\n%s\n' "$session_bridge_build_info" >&2
        exit 65
        ;;
esac

registration_bridge_binary="$verification/registration_bridge_contract"
"$clang" \
    -std=c11 \
    -Wall \
    -Wextra \
    -Werror \
    -target arm64-apple-macos26.0 \
    -isysroot "$sdk_path" \
    -I"$NATIVE_ROOT/Tests/Fakes" \
    -I"$NATIVE_ROOT/Sources/ChiakiNativeBridge/include" \
    "$NATIVE_ROOT/Sources/ChiakiNativeBridge/RemotePlayChiakiBridge.c" \
    "$NATIVE_ROOT/Tests/Fakes/fake_chiaki_runtime.c" \
    "$NATIVE_ROOT/Tests/registration_bridge_contract.c" \
    -o "$registration_bridge_binary"

registration_bridge_output="$("$registration_bridge_binary")"
if [ "$registration_bridge_output" != "REGISTRATION BRIDGE VERIFIED  exact PS5 identity/PIN/result and retry-safe lifecycle" ]; then
    printf 'Unexpected registration bridge contract output: %s\n' "$registration_bridge_output" >&2
    exit 65
fi

registration_socket_source="$WORKSPACE/sources/chiaki-ng/lib/src/regist.c"
if ! grep -q 'setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE' "$registration_socket_source"; then
    printf 'Registration source does not disable SIGPIPE on its TCP socket: %s\n' \
        "$registration_socket_source" >&2
    exit 65
fi

registration_socket_binary="$verification/registration_no_sigpipe_contract"
"$clang" \
    -std=c11 \
    -Wall \
    -Wextra \
    -Werror \
    -target arm64-apple-macos26.0 \
    -isysroot "$sdk_path" \
    "$NATIVE_ROOT/Tests/registration_no_sigpipe_contract.c" \
    -o "$registration_socket_binary"

registration_socket_output="$("$registration_socket_binary")"
if [ "$registration_socket_output" != "REGISTRATION SOCKET VERIFIED  closed-peer send returns EPIPE without SIGPIPE" ]; then
    printf 'Unexpected registration socket contract output: %s\n' \
        "$registration_socket_output" >&2
    exit 65
fi

local_only_holepunch_binary="$verification/local_only_holepunch_contract"
"$clang" \
    -std=c11 \
    -Wall \
    -Wextra \
    -Werror \
    -target arm64-apple-macos26.0 \
    -isysroot "$sdk_path" \
    -I"$WORKSPACE/sources/chiaki-ng/lib/include" \
    "$NATIVE_ROOT/Tests/local_only_holepunch_contract.c" \
    "$library" \
    -lz \
    -framework CoreServices \
    -framework Security \
    -framework SystemConfiguration \
    -framework CoreFoundation \
    -o "$local_only_holepunch_binary"

local_only_holepunch_output="$("$local_only_holepunch_binary")"
if [ "$local_only_holepunch_output" != "LOCAL-ONLY HOLEPUNCH VERIFIED  endpoint-free fail-closed compatibility surface" ]; then
    printf 'Unexpected local-only holepunch contract output: %s\n' \
        "$local_only_holepunch_output" >&2
    exit 65
fi

endpoint_pattern='auth\.api\.sonyentertainmentnetwork\.com|ca\.account\.sony\.com|remoteplay\.dl\.playstation\.net/remoteplay/redirect|web\.np\.playstation\.com|cloudAssistedNavigation|asm\.np\.community\.playstation\.net|mobile-pushcl\.np\.communication\.playstation\.net|sessionManager/v1/remotePlaySessions|psn:sessionManager|raw\.githubusercontent\.com/pradt2/always-online-stun'
for variant in \
    macos-arm64 \
    macos-x86_64 \
    xros-arm64 \
    xrsimulator-arm64 \
    iphoneos-arm64 \
    iphonesimulator-arm64; do
    variant_library="$WORKSPACE/products/$variant/libChiakiNative.a"
    if [ ! -f "$variant_library" ]; then
        printf 'Missing native product for endpoint audit: %s\n' "$variant_library" >&2
        exit 66
    fi
    member_list="$verification/$variant.members.txt"
    endpoint_strings="$verification/$variant.strings.txt"
    /usr/bin/ar -t "$variant_library" > "$member_list"
    /usr/bin/strings -a "$variant_library" > "$endpoint_strings"
    if grep -qx 'holepunch.c.o' "$member_list"; then
        printf 'Native product still contains the network holepunch implementation: %s\n' \
            "$variant_library" >&2
        exit 65
    fi
    if ! grep -qx 'holepunch-disabled.c.o' "$member_list"; then
        printf 'Native product is missing the fail-closed holepunch implementation: %s\n' \
            "$variant_library" >&2
        exit 65
    fi
    if grep -Eiq "$endpoint_pattern" "$endpoint_strings"; then
        printf 'Native product contains a prohibited Sony account/holepunch endpoint: %s\n' \
            "$variant_library" >&2
        exit 65
    fi
done

symbols="$verification/symbols.txt"
nm -g "$library" > "$symbols"
for symbol in \
    _rp_chiaki_runtime_info \
    _rp_chiaki_registration_handle_create \
    _rp_chiaki_registration_handle_destroy \
    _rp_chiaki_registration_start \
    _rp_chiaki_registration_request_stop \
    _rp_chiaki_registration_join \
    _rp_chiaki_session_handle_create \
    _rp_chiaki_session_handle_destroy \
    _rp_chiaki_wake_ps5 \
    _rp_chiaki_session_initialize \
    _rp_chiaki_session_start \
    _rp_chiaki_session_set_controller_state \
    _rp_chiaki_session_go_home \
    _rp_chiaki_session_go_to_bed \
    _rp_chiaki_session_request_stop \
    _rp_chiaki_session_join \
    _rp_chiaki_result_string; do
    if ! grep -q " $symbol$" "$symbols"; then
        printf 'Native library is missing bridge symbol %s\n' "$symbol" >&2
        exit 65
    fi
done

printf 'ABI VERIFIED  %s\n' "$abi_output"
printf 'ABI VERIFIED  macOS minimum 26.0\n'
printf '%s\n' "$wake_parser_output"
printf '%s\n' "$session_bridge_output"
printf '%s\n' "$registration_bridge_output"
printf '%s\n' "$registration_socket_output"
printf '%s\n' "$local_only_holepunch_output"
printf 'LOCAL-ONLY ENDPOINT AUDIT VERIFIED  six native variants\n'
