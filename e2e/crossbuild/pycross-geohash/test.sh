#!/usr/bin/env bash
#
# geohash_macos_wheels is tagged "manual" (see BUILD.bazel), so this is the
# only place that runs it — and only on a real macOS host, the one with an
# Xcode SDK to cross-build the macOS amd64 wheel from.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."  # e2e/crossbuild workspace root

BAZEL="${BAZEL:-bazel}"

if [[ "$(uname)" != "Darwin" ]]; then
    echo "Linux host — skipping the macOS cross target (no Xcode SDK available from here)"
    exit 0
fi

echo "macOS host detected — cross-building the macOS amd64 wheel too"
"$BAZEL" test --test_output=errors //pycross-geohash:geohash_macos_wheels_tags_test
