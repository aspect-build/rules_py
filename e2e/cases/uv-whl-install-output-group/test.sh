#!/usr/bin/env bash
set -euo pipefail

listing="$TEST_SRCDIR/_main/cases/uv-whl-install-output-group/listing.txt"

if [[ ! -f "$listing" ]]; then
    echo "FAIL: listing.txt was not produced by the genrule" >&2
    exit 1
fi

if [[ ! -s "$listing" ]]; then
    echo "FAIL: listing.txt is empty — install_dir output group exposed no files" >&2
    exit 1
fi

if ! grep -q "iniconfig" "$listing"; then
    echo "FAIL: expected iniconfig package files in install dir, got:" >&2
    cat "$listing" >&2
    exit 1
fi

echo "PASS: install_dir output group correctly exposed wheel contents to genrule"
