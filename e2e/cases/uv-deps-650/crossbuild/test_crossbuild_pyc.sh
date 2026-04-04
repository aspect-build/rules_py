#!/usr/bin/env bash
# Verifies that cross-arch whl_install with compile_pyc succeeds.
#
# Regression test for the exec-platform interpreter fix: when building
# arm64 Linux packages on an amd64 host with compile_pyc=True, the
# compileall action must use the exec-platform (amd64) interpreter.
# If the wrong interpreter is selected, the action fails with
# "Exec format error" at build time, which Bazel surfaces as a test failure.
#
# The fact that this test builds at all (its data deps are built before the
# test runs) is the assertion. No runtime logic is needed.
set -euo pipefail

DIR="${TEST_SRCDIR}/_main/cases/uv-deps-650/crossbuild"

# Confirm the arm64 layer tarballs were produced. The build of these targets
# exercises whl_install with compile_pyc=True against an arm64 target platform
# on whatever host this test runs on.
if ! ls "$DIR"/arm64_layers* >/dev/null 2>&1; then
    echo "FAIL: arm64 layer outputs not found in $DIR"
    echo "  This likely means the cross-arch whl_install build failed."
    exit 1
fi

echo "PASS: cross-arch whl_install with compile_pyc succeeded (arm64 layers built on $(uname -m) host)"
