#!/usr/bin/env bash
# EXEC_TOOLS_TOOLCHAIN must resolve the exec-platform Python interpreter even
# when the target platform is arm64 — unpack.py runs on the exec side, and an
# arm64 interpreter would fail with "Exec format error" on an amd64 host.
set -euo pipefail

DIR="${TEST_SRCDIR}/_main/tools"

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

# The arm64 transition changes the config fingerprint (the ST-* hash in the
# path) even when the resolved interpreter is the same exec tool, so path
# equality isn't a valid assertion — check neither path names an arm64/aarch64
# interpreter instead.
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