#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCK_FILE="$NATIVE_ROOT/Manifest/sources.lock"

required_columns=7
line_number=0
source_count=0

while IFS=$'\t' read -r name filename destination url expected_sha revision license extra; do
    line_number=$((line_number + 1))
    case "$name" in
        ''|'#'*) continue ;;
    esac

    source_count=$((source_count + 1))
    if [ -n "${extra:-}" ] || [ -z "$license" ]; then
        printf 'Invalid %s-column lock row at line %d\n' "$required_columns" "$line_number" >&2
        exit 65
    fi
    case "$expected_sha" in
        *[!0-9a-f]*|'')
            printf 'Invalid SHA-256 at line %d\n' "$line_number" >&2
            exit 65
            ;;
    esac
    if [ "${#expected_sha}" -ne 64 ]; then
        printf 'Invalid SHA-256 length at line %d\n' "$line_number" >&2
        exit 65
    fi
    case "$url" in
        https://*) ;;
        *)
            printf 'Non-HTTPS source URL at line %d\n' "$line_number" >&2
            exit 65
            ;;
    esac
done < "$LOCK_FILE"

if [ "$source_count" -ne 10 ]; then
    printf 'Expected 10 locked sources, found %d\n' "$source_count" >&2
    exit 65
fi

printf 'SOURCE VERIFIED  %d locked native sources\n' "$source_count"
cd "$NATIVE_ROOT"
shasum -a 256 -c <<'CHECKSUMS'
c9275adcbfb956abc70a1049e5aac98665ed0cb07dd97a79dd3ad56b4408875d  Patches/known-good-chiaki-curl-6b06124.patch
4845559153486a1b306e04262a4738307a873c7116aa0747137d70b0a1b3097b  Patches/known-good-chiaki-ng-6b06124.patch
2b1c52550f69493bd330354b85cea2bed4fcb230397ce700191e410f0cfe8a86  Patches/chiaki-ng-registration-no-sigpipe-2026-07-15.patch
74fcd463a819902d40cf3000f1f1c38cd31149b0fbf172bbe0da6a5146d8d97c  Patches/chiaki-ng-local-only-holepunch-2026-08-29.patch
CHECKSUMS
