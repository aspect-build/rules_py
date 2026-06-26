#!/usr/bin/env bash
#
# Regression test for https://github.com/aspect-build/rules_py/issues/1116:
# after the move to hermetic-launcher (#1045), `bazel run` on a minimal
# py_binary failed at runtime with `execve failed with errno 2`. The failure
# only reproduces under a real `bazel run` (the launcher is the top-level
# process and must self-locate its runfiles), so it can't be an `sh_test` under
# //... — CI runs this directly. Fixed in hermetic-launcher 0.0.11.
#
# Run from the e2e workspace root; override bazel with $BAZEL.
set -uo pipefail

cd "$(dirname "$0")/../.."  # e2e workspace root

BAZEL="${BAZEL:-bazel}"
TARGET="//cases/hermetic-launcher-1116:hello"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

echo "== bazel run on a minimal py_binary must succeed and print 'hello' =="
out_log="$(mktemp)"
trap 'rm -f "$out_log"' EXIT

# `bazel run` writes program output to stdout; keep bazel's own chatter on
# stderr out of the captured value by selecting the last line.
if ! "$BAZEL" run "$TARGET" >"$out_log" 2>&1; then
    cat "$out_log" >&2
    if grep -qi "execve failed" "$out_log"; then
        fail "bazel run regressed: launcher could not execve the venv python (issue #1116)"
    fi
    fail "expected 'bazel run $TARGET' to succeed"
fi

if ! grep -qx "hello" "$out_log"; then
    cat "$out_log" >&2
    fail "expected output 'hello' from $TARGET"
fi

echo "PASS: bazel run launches the py_binary and prints 'hello'"
