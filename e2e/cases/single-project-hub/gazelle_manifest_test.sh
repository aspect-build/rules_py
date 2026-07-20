#!/usr/bin/env bash
set -euo pipefail

manifest="${TEST_SRCDIR}/_main/single-project-hub/gazelle_python_manifest.yaml"
grep -Fq '    cowsay: cowsay' "$manifest" || {
    echo "FAIL: cowsay is missing from the Gazelle manifest" >&2
    exit 1
}
if grep -Eq '^    (wheel|packaging)(\.|:)' "$manifest"; then
    echo "FAIL: inactive dev dependencies leaked into the Gazelle manifest" >&2
    exit 1
fi
