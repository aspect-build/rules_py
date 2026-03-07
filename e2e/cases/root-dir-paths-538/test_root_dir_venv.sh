#!/usr/bin/env bash
set -euo pipefail

# Run the py_venv_binary from / using an absolute path.  The binary's
# run.tmpl.sh captures PWD="$(pwd)" which will be "/", and then uses
# alocation to make RUNFILES_DIR-relative paths absolute.  Even with
# absolute RUNFILES_DIR, check that no paths leak double slashes.
BINARY="$(cd "$TEST_SRCDIR/_main/cases/root-dir-paths-538" && pwd)/check_paths_venv_bin"

cd /
exec "$BINARY"
