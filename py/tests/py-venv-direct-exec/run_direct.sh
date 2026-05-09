#!/usr/bin/env bash
# $1 — basename of the launcher target (sibling in the runfiles tree).
# $2..$N — KEY=VALUE specs forwarded as argv to assert_env.py.
#
# Invokes the launcher directly, bypassing `bazel run` so
# RunEnvironmentInfo is NOT applied. Any env vars the script sees must
# come from substitutions baked into the launcher itself.
set -euo pipefail

ROOT="$(dirname "$0")"
launcher_name="$1"
shift

# Clear any env vars the test runner might have inherited so the
# launcher is the sole source of these names.
unset VENV_FOO EXEC_ONLY OVERRIDE_ME

exec "$ROOT/$launcher_name" "$@"
