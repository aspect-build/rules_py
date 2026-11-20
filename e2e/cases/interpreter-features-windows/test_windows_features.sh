#!/usr/bin/env bash
set -euo pipefail

# Checks this test's runfiles: each argument is present:<path> or
# absent:<path>, with <path> relative to the Windows interpreter repository.
ROOT="${TEST_SRCDIR}/rules_py++python_interpreters+python_3_13_x86_64_pc_windows_msvc"

errors=0

expect() {
    local want="${1%%:*}" path="${1#*:}"
    if [ -e "$ROOT/$path" ]; then
        local have=present
    else
        local have=absent
    fi
    if [ "$have" != "$want" ]; then
        echo "FAIL: $path is $have, want $want"
        errors=$((errors + 1))
    fi
}

for spec in "$@"; do expect "$spec"; done

[ "$errors" -eq 0 ]
