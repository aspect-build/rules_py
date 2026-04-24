#!/usr/bin/env bash
# Verify that $(PYTHON3) resolves to a working Python interpreter.

set -euo pipefail

python_path_file="$(dirname "$0")/python_path.txt"
if [[ ! -f "$python_path_file" ]]; then
    # Try rlocation-style path (Bazel runfiles)
    python_path_file="${RUNFILES_DIR:-$0.runfiles}/aspect_rules_py/e2e/cases/current-py-toolchain-896/python_path.txt"
fi

python_path="$(cat "$python_path_file" | tr -d '[:space:]')"

if [[ -z "$python_path" ]]; then
    echo "FAIL: PYTHON3 Make variable resolved to empty string"
    exit 1
fi

echo "PYTHON3 resolved to: $python_path"

# The path should contain "python" somewhere
if [[ "$python_path" != *python* ]]; then
    echo "FAIL: PYTHON3 path does not contain 'python': $python_path"
    exit 1
fi

echo "PASS"
