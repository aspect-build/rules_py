#!/usr/bin/env bash
# geohash_macos_amd64_cross_test is tagged "manual" (see BUILD.bazel), so
# this is the only place that runs it — and only on a real macOS host.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if [[ "$(uname)" == "Darwin" ]]; then
    echo "macOS host detected — building and running the macOS cross target too"
    bazel test --test_output=errors //geohash:geohash_macos_amd64_cross_test
else
    echo "Linux host — skipping macOS cross target (no Xcode SDK available from here)"
fi
