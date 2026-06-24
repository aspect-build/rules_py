#!/usr/bin/env bash
#
# These checks register synthetic target and exec Python toolchains in a nested
# module so they cannot affect the parent e2e workspace's toolchain resolution.
set -uo pipefail

case_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$case_dir" || exit 1

BAZEL="${BAZEL:-bazel}"
if ! "$BAZEL" test --lockfile_mode=off -- \
    //:compatible_metadata_test \
    //:compile_disabled_test \
    //:exec_runtime_only_test \
    //:magic_mismatch_test \
    //:missing_exec_magic_test \
    //:missing_target_magic_test \
    //:ordinary_runtime_pairs_test \
    //:unbound_exec_identity_test; then
    echo "FAIL: whl_install .pyc runtime compatibility checks failed" >&2
    exit 1
fi

echo "PASS: whl_install validates target and exec .pyc runtimes"
