#!/usr/bin/env bash
# geohash_macos_wheels is tagged "manual" (see pycross-geohash/BUILD.bazel),
# so this is the only place that runs it — and only on a real macOS host.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if [[ "$(uname)" == "Darwin" ]]; then
    echo "macOS host detected — cross-building the macOS amd64 wheel too"
    bazel test --test_output=errors //pycross-geohash:geohash_macos_wheels_tags_test
else
    echo "Linux host — skipping macOS cross target (no Xcode SDK available from here)"
fi
