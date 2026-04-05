#!/usr/bin/env bash
# Verifies that UNPACK_TOOLCHAIN always resolves the exec-platform binary,
# even when the target platform is arm64.
#
# The whl_install rule uses ctx.toolchains[UNPACK_TOOLCHAIN] directly because
# UNPACK_TOOLCHAIN is registered with exec_compatible_with, so Bazel always selects
# the exec-platform binary.
#
# This test confirms that: when we transition to an arm64 target platform on
# an amd64 exec host, the resolved unpack binary path still refers to the amd64
# binary (not an arm64 binary that would fail with "Exec format error").
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

echo "Native unpack path:       $native_path"
echo "Arm64-target unpack path: $arm64_path"

# The arm64 platform transition changes the configuration fingerprint (the
# ST-* hash in the output path) even when the resolved binary is the same
# exec-platform tool. Path equality is therefore not a valid assertion.
#
# What matters is that neither build resolved an arm64/aarch64 binary. If
# toolchain resolution used the target platform instead of the exec platform,
# the path would contain "arm64" or "aarch64" and the binary would fail at
# runtime with "Exec format error".
if [[ "$arm64_path" == *"arm64"* ]] || [[ "$arm64_path" == *"aarch64"* ]]; then
    echo "FAIL: arm64-target unpack path contains arm64/aarch64 — exec platform not honoured."
    echo "  Path: $arm64_path"
    exit 1
fi

if [[ "$native_path" == *"arm64"* ]] || [[ "$native_path" == *"aarch64"* ]]; then
    echo "FAIL: native unpack path unexpectedly contains arm64/aarch64."
    echo "  Path: $native_path"
    exit 1
fi

echo "PASS: UNPACK_TOOLCHAIN resolved exec-platform binary for arm64 target ($(uname -m) host)"
