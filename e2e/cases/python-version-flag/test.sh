#!/usr/bin/env bash
#
# The interpreter version must be selectable via EITHER version flag, with no
# python_version attr on the target:
#   - rules_py's native flag   (modern consumers)
#   - @rules_python's flag     (legacy consumers, inherited as a fallback)
# version_test asserts sys.version_info matches its argument, so a flag that
# failed to select would run the default version and fail. `bazel run` passes
# the expected version positionally, letting one target cover every
# provisioned version.
set -euo pipefail

cd "$(dirname "$0")/.."  # e2e/cases workspace root

BAZEL="${BAZEL:-bazel}"

# No flag at all: the version falls back to rules_python's default (3.11 for
# the rules_python version pinned in MODULE.bazel), through the same fallback
# path as the legacy flag. A failure here means the no-flag default moved.
"$BAZEL" run \
    --lockfile_mode=off \
    -- //python-version-flag:version_check 3.11

for version in 3.9 3.10 3.11 3.12 3.13; do
    # Modern: only rules_py's native flag is set.
    "$BAZEL" run \
        --lockfile_mode=off \
        "--@aspect_rules_py//py:python_version=${version}" \
        -- //python-version-flag:version_check "${version}"

    # Legacy: only @rules_python's flag is set. The py_* transition
    # normalizes both flags, so this converges to the same target config
    # as the run above — what it adds is the flag-inheritance entry point.
    "$BAZEL" run \
        --lockfile_mode=off \
        "--@rules_python//python/config_settings:python_version=${version}" \
        -- //python-version-flag:version_check "${version}"
done
