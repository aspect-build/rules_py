#!/usr/bin/env bash
#
# The prerelease-marker check builds under a specific --python_version /
# --dep_group flag combination, so it can't be an sh_test under //...; CI runs
# it directly. The //:regular and //:freethreaded metadata tests run under //...
set -uo pipefail

case_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$case_dir" || exit 1

BAZEL="${BAZEL:-bazel}"
if ! "$BAZEL" build \
    --lockfile_mode=off \
    --@aspect_rules_py//py:python_version=3.15.0a6 \
    --@aspect_rules_py//uv/private/constraints/dep_group:dep_group=interpreter-runtime-metadata \
    -- //:prerelease_dependency_not_selected; then
    echo "FAIL: a final-release-only uv dependency was selected for Python 3.15.0a6" >&2
    exit 1
fi

echo "PASS: PBS runtime metadata matches the selected interpreter"
