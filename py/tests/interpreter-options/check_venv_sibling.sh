#!/usr/bin/env bash
# Verify `interpreter_options` reaches the public sibling
# `:{name}.venv` emitted by `py_binary(expose_venv = True)`. The
# launcher's exec line should use `-O` (or whatever was passed), so
# `sys.flags.optimize` is 1 when the venv is invoked with `-c ...`.
#
# We can't `bazel run :bin.venv` from inside a test, but the venv's
# generated executable is just a bash script — invoke it directly.
set -euo pipefail

ROOT="$(dirname "$0")"
"$ROOT"/bin_O.venv -c 'import sys; sys.exit(0 if sys.flags.optimize == 1 else 1)'
