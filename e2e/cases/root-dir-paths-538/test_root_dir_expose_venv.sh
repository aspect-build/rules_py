#!/usr/bin/env bash
set -euo pipefail

# Same regression shape as test_root_dir_venv.sh, but against a binary
# declared with `py_binary(expose_venv = True, ...)` — exercises the
# split codepath directly (no py_venv_binary alias in the middle).
BINARY="$(cd "$TEST_SRCDIR/_main/cases/root-dir-paths-538" && pwd)/check_paths_expose_venv"

cd /
exec "$BINARY"
