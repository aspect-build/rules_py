#!/usr/bin/env bash
# Check that a native extension .so inside a tar is ELF for the expected arch.
#
# Uses only POSIX utilities (tar, od, find) — no Python dependency.
#
# Usage: check_so_arch.sh <tar_file> <so_path_grep_pattern> <expected_machine_le_hex>
#   so_path_grep_pattern: grep -E pattern matching the .so's full path inside
#     the tar, specific enough to pick exactly one .so if the tar bundles
#     more than the package under test (e.g. a reference build for diffing).
#   expected_machine_le_hex: ELF e_machine as little-endian hex bytes
#     x86_64  (EM_X86_64  = 62  = 0x3e) → "3e00"
#     aarch64 (EM_AARCH64 = 183 = 0xb7) → "b700"
set -euo pipefail

tar_file="${1:?usage: check_so_arch.sh <tar_file> <so_path_grep_pattern> <expected_machine_le_hex>}"
so_pattern="${2:?so path grep pattern}"
expected="${3:?expected ELF machine as little-endian hex}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
tar xf "$tar_file" -C "$tmp" 2>/dev/null || true

so="$(cd "$tmp" && find . -type f | grep -E "$so_pattern" | head -1)"
if [ -z "$so" ]; then
    echo "FAIL: no .so matching '$so_pattern' found in $tar_file"
    exit 1
fi
so="$tmp/$so"

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
