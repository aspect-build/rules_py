#!/usr/bin/env bash
# Stand-in for a compressor libarchive has no filter for. It reads the archive
# on stdin and writes its own container to stdout: a 4-byte magic followed by a
# gzip stream. The magic matters — it makes the output provably NOT gzip, so a
# test that reads it back is exercising this program rather than accidentally
# succeeding on bytes bsdtar could have written itself.
set -euo pipefail
if [[ "${1:-}" != "--loud" ]]; then
    echo "fake_compressor: expected --loud, got '${1:-}'" >&2
    exit 1
fi
printf 'LOLZ'
exec gzip -9 -n
