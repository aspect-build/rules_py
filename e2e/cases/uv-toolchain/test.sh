#!/usr/bin/env bash
set -euo pipefail

# Verifies that the UV toolchains registered via uv.toolchain() are discoverable
# and that named hubs produce distinct binaries.

check() {
    local hub="$1" expected="$2"
    local out
    out="$(cat "${TEST_SRCDIR}/_main/cases/uv-toolchain/${hub}_version.txt")"
    if [[ "$out" != *"$expected"* ]]; then
        echo "FAIL: @${hub} — expected to contain '${expected}', got: ${out}" >&2
        exit 1
    fi
    echo "PASS: @${hub} — ${out}"
}

check uv             "uv 0.11.6"
check uv_legacy      "uv 0.10.12"
check uv_custom      "uv 0.11.5"
check uv_mirror      "uv 0.11.6"
check uv_bazel_fork  "d9e73e850"
