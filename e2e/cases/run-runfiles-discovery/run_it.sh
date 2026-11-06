#!/usr/bin/env bash
# Regression test: a py_binary must be runnable via `bazel run` (and directly),
# where the launcher discovers its own `.runfiles` dir from argv[0] rather than
# relying on a pre-set RUNFILES_DIR.
#
# `bazel test` sets RUNFILES_DIR for the test, which masks the bug. We reproduce
# the `bazel run` / direct-exec path by UNSETTING the runfiles env vars before
# invoking the binary, forcing the launcher to self-locate its runfiles.
#
# BUG (hermetic_launcher 0.0.9): without RUNFILES_DIR/RUNFILES_MANIFEST_FILE set,
# the launcher fails to resolve the embedded venv-python rlocation and aborts
# with "execve failed with errno 2". Works when RUNFILES_DIR is pre-set.
set -euo pipefail

bin="$1"
unset RUNFILES_DIR RUNFILES_MANIFEST_FILE JAVA_RUNFILES || true
output="$("$bin")"
if [[ "$output" != *"Hello, world!"* ]]; then
  echo "FAIL: expected 'Hello, world!', got: $output" >&2
  exit 1
fi
echo "PASS: py_binary ran via self-located runfiles"
