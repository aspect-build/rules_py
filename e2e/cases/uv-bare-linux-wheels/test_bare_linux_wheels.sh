#!/usr/bin/env bash
set -euo pipefail

TARGETS_FILE="${TEST_SRCDIR}/_main/uv-bare-linux-wheels/grpcio_targets"
TARGETS="$(cat "$TARGETS_FILE")"

if ! grep -q 'constraints/platform:linux_armv7l' <<< "$TARGETS"; then
    echo "FAIL: :linux_armv7l constraint missing from deps(@pypi-bare-linux-wheels//grpcio) — bare linux_* wheel tags were filtered out"
    echo ""
    echo "Platform constraints found:"
    grep 'constraints/platform' <<< "$TARGETS" || echo "  (none)"
    exit 1
fi

echo "PASS: :linux_armv7l referenced — grpcio's bare linux_* wheels survived lockfile parsing"
