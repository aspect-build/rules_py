#!/usr/bin/env bash
set -euo pipefail

# Windows cross-build test: verify that interpreter provisioning and wheel
# selection work correctly for Windows targets.

DIR="${TEST_SRCDIR}/_main/cases/windows-crossbuild"

WIN_X64_DEPS="$(cat "$DIR/windows_x64_toolchain_deps")"
WIN_ARM64_DEPS="$(cat "$DIR/windows_arm64_toolchain_deps")"
PYWIN32_DEPS="$(cat "$DIR/pywin32_deps")"

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

# Check 4: pywin32 deps include Windows wheel targets (win_amd64)
if ! echo "$PYWIN32_DEPS" | grep -q 'win_amd64'; then
    echo "FAIL: No win_amd64 wheel target found in pywin32 deps"
    errors=$((errors + 1))
else
    echo "PASS: pywin32 has win_amd64 wheel targets"
fi

# Check 5: pywin32 deps include win32 wheel targets
if ! echo "$PYWIN32_DEPS" | grep -q 'win32\.whl'; then
    echo "FAIL: No win32 wheel target found in pywin32 deps"
    errors=$((errors + 1))
else
    echo "PASS: pywin32 has win32 wheel targets"
fi

if [ "$errors" -gt 0 ]; then
    echo ""
    echo "FAILED: $errors check(s) failed"
    exit 1
fi

echo ""
echo "PASS: Windows cross-build infrastructure verified"
echo "  - Windows interpreter toolchains provisioned from PBS (x86_64, aarch64)"
echo "  - Windows-only native wheels (pywin32) available"
