#!/usr/bin/env bash
# Check that _geohash.so inside a py_image_layer tar is ELF for the expected arch.
#
# Uses only POSIX utilities (tar, od, find) — no Python dependency.
#
# Usage: check_so_arch.sh <tar_file> <expected_machine_le_hex>
#   expected_machine_le_hex: ELF e_machine as little-endian hex bytes
#     x86_64  (EM_X86_64  = 62  = 0x3e) → "3e00"
#     aarch64 (EM_AARCH64 = 183 = 0xb7) → "b700"
set -euo pipefail

tar_file="${1:?usage: check_so_arch.sh <tar_file> <expected_machine_le_hex>}"
expected="${2:?expected ELF machine as little-endian hex}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
tar xf "$tar_file" -C "$tmp" 2>/dev/null || true

so="$(find "$tmp" -name '_geohash*.so' -type f | head -1)"
if [ -z "$so" ]; then
    echo "FAIL: no _geohash*.so found in $tar_file"
    exit 1
fi

magic="$(od -A n -t x1 -N 4 "$so" | tr -d ' ')"
if [ "$magic" != "7f454c46" ]; then
    echo "FAIL: $(basename "$so") is not ELF (magic=0x${magic})"
    exit 1
fi

machine="$(od -A n -t x1 -j 18 -N 2 "$so" | tr -d ' ')"
if [ "$machine" != "$expected" ]; then
    echo "FAIL: $(basename "$so") ELF machine=0x${machine} expected=0x${expected}"
    exit 1
fi

echo "PASS: $(basename "$so") is ELF machine=0x${machine}"
