#!/usr/bin/env bash
#
# These checks load generated repositories from a nested module, so CI runs
# them directly rather than through the parent e2e workspace.
set -uo pipefail

case_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$case_dir" || exit 1

BAZEL="${BAZEL:-bazel}"
if ! "$BAZEL" test --lockfile_mode=off -- \
    //:regular \
    //:freethreaded; then
    echo "FAIL: prerelease runtime metadata did not match" >&2
    exit 1
fi

if ! "$BAZEL" build \
    --lockfile_mode=off \
    --@aspect_rules_py//py:python_version=3.15 \
    --@rules_python//python/config_settings:python_version=3.15.0a6 \
    --@aspect_rules_py//uv/private/constraints/dep_group:dep_group=interpreter-runtime-metadata \
    --@aspect_rules_py//uv/private/constraints/platform:platform_libc=glibc \
    --platforms=//:linux_x86_64 \
    -- //:prerelease_dependency_not_selected; then
    echo "FAIL: a final-release-only uv dependency was selected for Python 3.15.0a6" >&2
    exit 1
fi

echo "PASS: PBS runtime metadata matches the selected interpreter"
