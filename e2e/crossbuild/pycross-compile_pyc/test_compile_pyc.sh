#!/usr/bin/env bash
# Assert the cross-built (arm64) filelock install tree carries precompiled
# .pyc files. The data dep building at all already proves compileall did not
# pick the target-arch interpreter (the original "Exec format error"
# regression); the count check below additionally catches compileall being
# silently skipped.
set -euo pipefail

install_root="$(find "$TEST_SRCDIR" -type d -path '*whl_install__pycross_pure_python__filelock*' -name '*.install' | head -1)"
if [ -z "$install_root" ]; then
    echo "FAIL: filelock whl_install tree not found under TEST_SRCDIR"
    exit 1
fi

count="$(find "$install_root" -path '*/filelock/__pycache__/*.pyc' | wc -l)"
if [ "$count" -lt 1 ]; then
    echo "FAIL: no precompiled .pyc under $install_root"
    echo "whl_install's compileall either failed to run for this configuration"
    echo "or was silently skipped (see exec_matches_target in"
    echo "uv/private/whl_install/rule.bzl)."
    exit 1
fi

echo "PASS: $count precompiled .pyc files in the cross-built filelock install"
