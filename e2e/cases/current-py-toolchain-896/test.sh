#!/usr/bin/env bash
#
# report_version and report_exec_version resolve their toolchain without the
# py_* version transition, so each prints the requested version only if the
# version flag is authoritative in the interpreter hub. The @rules_python
# fallback flag is swept in e2e/rules-python-interop, the workspace that can
# name it.
set -euo pipefail

cd "$(dirname "$0")/.."  # e2e/cases workspace root

BAZEL="${BAZEL:-bazel}"

check_runtime_version() {
    local target="$1"
    local version="$2"
    local got
    got="$("$BAZEL" run --lockfile_mode=off \
        "--@aspect_rules_py//py:python_version=${version}" \
        -- "${target}" 2>/dev/null)"
    if [[ "${got}" != "${version}" ]]; then
        echo "FAIL: set python_version=${version}, but ${target} reports ${got}" >&2
        exit 1
    fi
}

for version in 3.9 3.10 3.11 3.12 3.13; do
    check_runtime_version //current-py-toolchain-896:report_version "${version}"
    check_runtime_version //current-py-toolchain-896:report_exec_version "${version}"
done
