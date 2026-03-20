#!/usr/bin/env bash
set -euo pipefail

# Windows cross-build test: verify that interpreter provisioning works
# correctly for Windows targets from a Linux host.

DIR="${TEST_SRCDIR}/_main/cases/windows-crossbuild-837"

WIN_X64_DEPS="$(cat "$DIR/windows_x64_toolchain_deps")"
WIN_ARM64_DEPS="$(cat "$DIR/windows_arm64_toolchain_deps")"

errors=0

# Check 1: Windows x86_64 toolchain resolved and has deps
if [ -z "$WIN_X64_DEPS" ]; then
    echo "FAIL: Windows x86_64 toolchain has no deps (not provisioned?)"
    errors=$((errors + 1))
else
    echo "PASS: Windows x86_64 interpreter toolchain provisioned"
fi

# Check 2: Windows aarch64 toolchain resolved and has deps
if [ -z "$WIN_ARM64_DEPS" ]; then
    echo "FAIL: Windows aarch64 toolchain has no deps (not provisioned?)"
    errors=$((errors + 1))
else
    echo "PASS: Windows aarch64 interpreter toolchain provisioned"
fi

# Check 3: Windows x86_64 toolchain references the interpreter repo
if ! echo "$WIN_X64_DEPS" | grep -q 'x86_64_pc_windows_msvc'; then
    echo "FAIL: Windows x86_64 toolchain doesn't reference expected interpreter repo"
    errors=$((errors + 1))
else
    echo "PASS: Windows x86_64 toolchain references correct interpreter repo"
fi

if [ "$errors" -gt 0 ]; then
    echo ""
    echo "FAILED: $errors check(s) failed"
    exit 1
fi

echo ""
echo "PASS: Windows cross-build interpreter provisioning verified"
echo "  - Windows interpreter toolchains provisioned from PBS (x86_64, aarch64)"
