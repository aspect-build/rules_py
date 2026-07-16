#!/usr/bin/env bash
#
# report_version resolves the runtime toolchain without the py_* version
# transition, so it prints the requested version only if the version flag is
# authoritative in the interpreter hub. Both the native flag and
# @rules_python's fallback must select the requested version.
set -euo pipefail

cd "$(dirname "$0")/.."  # e2e/cases workspace root

BAZEL="${BAZEL:-bazel}"

check_runtime_version() {
    local flag="$1"
    local version="$2"
    local got
    got="$("$BAZEL" run --lockfile_mode=off "--${flag}=${version}" \
        -- //current-py-toolchain-896:report_version 2>/dev/null)"
    if [[ "${got}" != "${version}" ]]; then
        echo "FAIL: set ${flag}=${version}, but runtime toolchain is ${got}" >&2
        exit 1
    fi
}

for version in 3.9 3.10 3.11 3.12 3.13; do
    check_runtime_version @aspect_rules_py//py:python_version "${version}"
    check_runtime_version @rules_python//python/config_settings:python_version "${version}"
done
