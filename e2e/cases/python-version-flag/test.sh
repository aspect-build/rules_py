#!/usr/bin/env bash
#
# The interpreter version must be selectable via rules_py's native version
# flag, with no python_version attr on the target. (@rules_python's flag is the
# legacy fallback entry point; it's swept in e2e/rules-python-interop, the
# workspace that can name it.)
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

for version in 3.10 3.11 3.12 3.13 3.14; do
    "$BAZEL" run \
        --lockfile_mode=off \
        "--@aspect_rules_py//py:python_version=${version}" \
        -- //python-version-flag:version_check "${version}"
done

# The native flag takes precedence over the legacy fallback when both are set.
"$BAZEL" run \
    --lockfile_mode=off \
    --@aspect_rules_py//py:python_version=3.12 \
    --@rules_python//python/config_settings:python_version=3.11 \
    -- //python-version-flag:version_check 3.12
