#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/../.."  # e2e workspace root

BAZEL="${BAZEL:-bazel}"

check_toolchain() {
    local version="$1"
    local freethreaded="$2"
    local platform="$3"
    shift 3

    local platform_flags=()
    if [[ "$platform" == "linux_x86_64" ]]; then
        platform_flags+=(--@aspect_rules_py//uv/private/constraints/platform:platform_libc=glibc)
    fi

    "$BAZEL" build \
        --lockfile_mode=off \
        "--@rules_python//python/config_settings:python_version=${version}" \
        "--@aspect_rules_py//py/private/interpreter:freethreaded=${freethreaded}" \
        "${platform_flags[@]}" \
        "--platforms=//cases/pbs-cc-toolchain:${platform}" \
        -- "$@"
}

check_toolchain 3.13 false linux_x86_64 //cases/pbs-cc-toolchain:regular_313
check_toolchain 3.13 true linux_x86_64 //cases/pbs-cc-toolchain:freethreaded_313
check_toolchain 3.13 false windows_x86_64 //cases/pbs-cc-toolchain:windows_regular_313
check_toolchain 3.13 true windows_x86_64 //cases/pbs-cc-toolchain:windows_freethreaded_313

host_flags=()
if [[ "$(uname -s)" == "Linux" ]]; then
    host_flags+=(--@aspect_rules_py//uv/private/constraints/platform:platform_libc=glibc)
fi

if [[ "$(uname -s)" == "Darwin" ]]; then
    library_target="@aspect_rules_py//py/tests/cc-deps:example_library.so"
    "$BAZEL" build \
        --lockfile_mode=off \
        --@rules_python//python/config_settings:python_version=3.13 \
        -- "$library_target"
    library="$("$BAZEL" cquery \
        --lockfile_mode=off \
        --@rules_python//python/config_settings:python_version=3.13 \
        --output=files \
        -- "$library_target")"
    if otool -L "$library" | grep -Fq 'libpython'; then
        otool -L "$library" >&2
        echo "FAIL: Python extension links libpython on macOS" >&2
        exit 1
    fi
fi

# The root suite covers the regular mode; repeat its native-extension test with
# free-threaded runtime and C toolchains selected from the PBS archive.
"$BAZEL" test \
    --lockfile_mode=off \
    --@rules_python//python/config_settings:python_version=3.13 \
    --@aspect_rules_py//py/private/interpreter:freethreaded=true \
    "${host_flags[@]}" \
    -- @aspect_rules_py//py/tests/cc-deps:test_smoke
