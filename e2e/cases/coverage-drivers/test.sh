#!/usr/bin/env bash
#
# End-to-end `bazel coverage` check for both test drivers.
#
# `bazel test //...` exercises the drivers themselves. This script exercises the
# *coverage* path, which only fires under `bazel coverage`: Bazel sets
# COVERAGE_MANIFEST / COVERAGE_OUTPUT_FILE and collects each test's LCOV. It
# asserts that both pytest_main.py and unittest_main.py emit Bazel-consumable
# LCOV for the shared library `foo.py`, with the SF: path fixup (coveragepy#963)
# and the FN: two-field fixup (bazel#25118) applied.
#
# Can't be an sh_test (needs a real top-level `bazel coverage`); the
# cases/test.sh aggregator runs it. Override bazel with $BAZEL.
set -euo pipefail

cd "$(dirname "$0")/.."  # e2e/cases workspace root

BAZEL="${BAZEL:-bazel}"

check_coverage() {
    local target="$1"
    local datfile="$2"

    echo "== bazel coverage ${target} =="
    # ^//coverage-drivers instruments this case's own sources (foo.py + the test
    # src) and excludes the @pypi_coverage_drivers wheels.
    "$BAZEL" coverage --instrumentation_filter=^//coverage-drivers "${target}"

    [[ -s "${datfile}" ]] || {
        echo "FAIL: coverage data missing or empty: ${datfile}" >&2
        exit 1
    }

    # foo.py must appear; the abs-path -> manifest-path fixup (coveragepy#963)
    # rewrites coverage.py's symlink-followed path back to the source name.
    grep -qE '^SF:.*foo\.py$' "${datfile}" || {
        echo "FAIL: no SF: record for foo.py in ${datfile}" >&2
        cat "${datfile}" >&2
        exit 1
    }

    # At least one line hit (DA:<line>,<count>=1) — foo.py's functions ran.
    grep -qE '^DA:[0-9]+,[1-9]' "${datfile}" || {
        echo "FAIL: no covered lines (DA:<line>,>=1) in ${datfile}" >&2
        cat "${datfile}" >&2
        exit 1
    }

    # FN: records must be two-field (FN:<line>,<name>); the three-field
    # coverage.py shape breaks Bazel's LCOV parser (bazel#25118).
    if grep -qE '^FN:[0-9]+,[0-9]+,' "${datfile}"; then
        echo "FAIL: FN: records still three-field — bazel#25118 fixup regressed" >&2
        cat "${datfile}" >&2
        exit 1
    fi

    echo "OK: ${target} emitted LCOV with foo.py coverage and the expected fixups."
}

check_coverage //coverage-drivers:coverage_pytest_test bazel-testlogs/coverage-drivers/coverage_pytest_test/coverage.dat
check_coverage //coverage-drivers:coverage_pytest_codegen_test bazel-testlogs/coverage-drivers/coverage_pytest_codegen_test/coverage.dat
check_coverage //coverage-drivers:coverage_unittest_test bazel-testlogs/coverage-drivers/coverage_unittest_test/coverage.dat

echo "All coverage driver checks passed."
