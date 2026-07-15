#!/usr/bin/env bash
#
# report_exec_version resolves rules_python's exec-tools toolchain without the
# py_* version transition, so it prints the requested version only if the
# version flag is authoritative in the interpreter hub. Both the native flag
# and @rules_python's fallback must select the requested version.
set -euo pipefail

cd "$(dirname "$0")/.."  # e2e/cases workspace root

BAZEL="${BAZEL:-bazel}"

check_exec_version() {
    local flag="$1"
    local version="$2"
    local got
    got="$("$BAZEL" run --lockfile_mode=off "--${flag}=${version}" \
        -- //rules-python-consumers:report_exec_version 2>/dev/null)"
    if [[ "${got}" != "${version}" ]]; then
        echo "FAIL: set ${flag}=${version}, but exec-tools runtime is ${got}" >&2
        exit 1
    fi
}

for version in 3.9 3.10 3.11 3.12 3.13; do
    check_exec_version @aspect_rules_py//py:python_version "${version}"
    check_exec_version @rules_python//python/config_settings:python_version "${version}"
done

"$BAZEL" build \
    --lockfile_mode=off \
    --@aspect_rules_py//py:python_version=3.13 \
    --@aspect_rules_py//uv/private/constraints/platform:platform_libc=glibc \
    --platforms=//pbs-cc-toolchain:linux_x86_64 \
    -- \
    //pbs-cc-toolchain:embed_python \
    //pbs-cc-toolchain:embed_python_abi3 \
    //pbs-cc-toolchain:regular_313 \
    //rules-python-consumers:python_launcher

bazel_bin="$("$BAZEL" info --lockfile_mode=off bazel-bin)"
version="$(<"${bazel_bin}/rules-python-consumers/python_launcher.txt")"
if [[ "${version}" != "3.13" ]]; then
    echo "FAIL: rules_py Python version selected launcher ${version}, expected 3.13" >&2
    exit 1
fi

echo "PASS: rules_py Python version selected the 3.13 launcher and C toolchain"
