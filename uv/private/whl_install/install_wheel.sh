#!/usr/bin/env bash
set -euo pipefail

# Usage: install_wheel.sh <unpack_bin> <python> <unpack_args...>
#
# Unpacks a wheel and pre-compiles .py files to .pyc bytecode.

UNPACK="$1"; shift
PYTHON="$1"; shift

# Unpack the wheel (passes through --into, --wheel, --python-version-* args)
"${UNPACK}" "$@"

# Extract the --into directory from the unpack args for compileall.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --into) OUT_DIR="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# Pre-compile .py to .pyc bytecode so that test invocations using -B
# (don't write bytecode) can still read cached bytecode instead of
# recompiling every import from source on every run.
#
# Flags:
#   -q: Suppress per-file output.
#   --invalidation-mode unchecked-hash: Don't check source file timestamps
#     or hashes at import time. Safe because Bazel artifacts are immutable
#     once cached — the .py files will never change under a given .pyc.
#
# Non-fatal: some wheels ship .py files that can't compile under all Python
# versions (e.g., debugpy vendors Python 2 code).
"${PYTHON}" -m compileall -q --invalidation-mode unchecked-hash "${OUT_DIR}" || \
    echo "warning: bytecode compilation failed" >&2
