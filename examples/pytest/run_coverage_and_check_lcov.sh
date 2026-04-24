#!/usr/bin/env bash
# Drives :coverage_setup_test manually with COVERAGE_MANIFEST and
# COVERAGE_OUTPUT_FILE set, then asserts that pytest_main.py wrote an
# LCOV file with the expected shape. See the BUILD.bazel comment on
# coverage_lcov_shape_test for the full setup story.

set -euo pipefail

LAUNCHER="$TEST_SRCDIR/_main/examples/pytest/coverage_setup_test"
MANIFEST="$TEST_SRCDIR/_main/examples/pytest/coverage_manifest.txt"

[[ -x "$LAUNCHER" ]] || { echo "launcher not found or not executable: $LAUNCHER" >&2; exit 1; }
[[ -f "$MANIFEST" ]] || { echo "manifest not found: $MANIFEST" >&2; exit 1; }

LCOV="$(mktemp -d)/coverage.lcov"

# Point pytest_main.py's coverage branch at our synthesized inputs.
# The launcher would normally be invoked by `bazel coverage`, which
# sets these vars automatically; here we're exercising the same
# codepath without the bazel-coverage driver.
#
# The launcher must run with cwd = workspace root so pytest_main.py
# can resolve `<package>/<target_name>.pytest_paths` for pytest
# collection. The sandbox's initial cwd is the workspace root, so we
# leave it alone; coverage.py's side-output (.coverage) lands there
# too, which is fine — the sandbox is disposable.
COVERAGE_MANIFEST="$MANIFEST" \
  COVERAGE_OUTPUT_FILE="$LCOV" \
  "$LAUNCHER"

# Verify the LCOV has the expected shape.
[[ -s "$LCOV" ]] || { echo "LCOV file empty or missing: $LCOV" >&2; exit 1; }

# SF: records should name the file(s) listed in the manifest. The
# absolute-path → manifest-path fixup in pytest_main.py should have
# rewritten coverage.py's follow-symlinks absolute path back to the
# original "examples/pytest/foo.py" entry.
grep -qE '^SF:.*examples/pytest/foo\.py$' "$LCOV" || {
  echo "Expected SF: record for examples/pytest/foo.py not found in LCOV." >&2
  echo "LCOV contents:" >&2
  cat "$LCOV" >&2
  exit 1
}

# DA: records should have two-field format (line,hitcount), with at
# least one hit — foo_test.py calls foo.add(), so line 2 of foo.py is
# covered.
grep -qE '^DA:[0-9]+,[0-9]+$' "$LCOV" || {
  echo "Expected DA: records not found in LCOV." >&2
  echo "LCOV contents:" >&2
  cat "$LCOV" >&2
  exit 1
}

# FN: records should have the Bazel-issue-25118 fixup applied: two
# fields (FN:<line>,<name>), never three (FN:<start>,<end>,<name>).
if grep -qE '^FN:[0-9]+,[0-9]+,' "$LCOV"; then
  echo "FN: records still have the three-field shape — the bazelbuild/bazel#25118" >&2
  echo "workaround in pytest_main.py may have regressed." >&2
  echo "LCOV contents:" >&2
  cat "$LCOV" >&2
  exit 1
fi

echo "OK: coverage LCOV has expected SF/DA records and the FN fixup is applied."
