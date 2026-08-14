#!/usr/bin/env bash
# geohash_main.py asserts geohash.encode(37.7749, -122.4194) itself and only
# prints "OK" on success, so this just has to confirm the binary reached
# that point rather than re-checking the expected geohash value here too.
set -euo pipefail

bin="${1:?usage: check_geohash_output.sh <geohash_bin path>}"
expected="OK"

actual="$("$bin")"
if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: $bin printed '$actual', expected '$expected'"
    exit 1
fi

echo "PASS: $bin printed '$actual'"
