#!/usr/bin/env bash
# Verifies that EXEC_TOOLS_TOOLCHAIN always resolves the exec-platform Python
# interpreter, even when the target platform is arm64.
#
# The whl_install and py_unpacked_wheel rules use ctx.toolchains[EXEC_TOOLS_TOOLCHAIN]
# to run unpack.py. That toolchain is registered with exec_compatible_with, so Bazel
# must always select the interpreter that runs on the build host — never an arm64
# binary that would fail with "Exec format error" on an amd64 host.
#
# This test confirms that: when we transition to an arm64 target platform on
# an amd64 exec host, the resolved Python interpreter path still refers to an
# amd64 (host) binary.
set -euo pipefail

DIR="${TEST_SRCDIR}/_main/cases/uv-deps-650/crossbuild"

native_path_file="$DIR/unpack_path.txt"
arm64_path_file="$DIR/unpack_path_for_arm64.txt"

if [[ ! -f "$native_path_file" ]]; then
    echo "FAIL: $native_path_file not found"
    exit 1
fi

if [[ ! -f "$arm64_path_file" ]]; then
    echo "FAIL: $arm64_path_file not found"
    exit 1
fi

native_path=$(cat "$native_path_file")
arm64_path=$(cat "$arm64_path_file")

echo "Native exec Python path:       $native_path"
echo "Arm64-target exec Python path: $arm64_path"

# The arm64 platform transition changes the configuration fingerprint (the
# ST-* hash in the output path) even when the resolved interpreter is the same
# exec-platform tool. Path equality is therefore not a valid assertion.
#
# What matters is that neither build resolved an arm64/aarch64 interpreter. If
# toolchain resolution used the target platform instead of the exec platform,
# the path would contain "arm64" or "aarch64" and the interpreter would fail at
# runtime with "Exec format error".
if [[ "$arm64_path" == *"arm64"* ]] || [[ "$arm64_path" == *"aarch64"* ]]; then
    echo "FAIL: arm64-target exec Python path contains arm64/aarch64 — exec platform not honoured."
    echo "  Path: $arm64_path"
    exit 1
fi

if [[ "$native_path" == *"arm64"* ]] || [[ "$native_path" == *"aarch64"* ]]; then
    echo "FAIL: native exec Python path unexpectedly contains arm64/aarch64."
    echo "  Path: $native_path"
    exit 1
fi

echo "PASS: EXEC_TOOLS_TOOLCHAIN resolved exec-platform Python for arm64 target ($(uname -m) host)"