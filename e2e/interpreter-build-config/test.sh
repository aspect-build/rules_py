#!/usr/bin/env bash
#
# These cases need their own root modules (build_config is hub-wide, and most
# assert module-extension evaluation failures), so they cannot be sh_tests
# under //...; CI runs this script directly.
set -uo pipefail

case_dir="$(cd "$(dirname "$0")" && pwd)"
BAZEL="${BAZEL:-bazel}"
failure_log="$(mktemp)"
trap 'rm -f "$failure_log"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

expect_failure() {
    local fixture="$1"
    local expected="$2"
    local target="${3:-@python_interpreters//:*}"

    if (
        cd "$case_dir/$fixture" &&
            "$BAZEL" query --lockfile_mode=off -- "$target"
    ) >"$failure_log" 2>&1; then
        fail "$fixture unexpectedly succeeded"
    fi
    if ! grep -Fq "$expected" "$failure_log"; then
        cat "$failure_log" >&2
        fail "$fixture did not report: $expected"
    fi
}

expect_success() {
    local fixture="$1"
    local target="$2"

    if ! (
        cd "$case_dir/$fixture" &&
            "$BAZEL" test --lockfile_mode=off -- "$target"
    ) >"$failure_log" 2>&1; then
        cat "$failure_log" >&2
        fail "$fixture failed"
    fi
}

# The only runtime coverage for a "-full" default mode: tar.zst extraction
# with strip_prefix python/install, and abi_flags "d" in the repo layout.
expect_success \
    root-debug-full-build-config \
    //:check
# Platforms the build_config doesn't cover still generate a repo name (so
# use_repo() imports stay valid) but fail at load time with an explanation.
expect_failure \
    root-debug-full-build-config \
    "No CPython 3.13 'debug-full' archive for x86_64-pc-windows-msvc" \
    '@python_3_13_x86_64_pc_windows_msvc//:*'

# The stub must not break eager fetching (`bazel fetch --all`, `bazel vendor`):
# the repo materializes cleanly and only referencing its targets errors.
if ! (
    cd "$case_dir/root-debug-full-build-config" &&
        "$BAZEL" fetch --lockfile_mode=off --repo=@python_3_13_x86_64_pc_windows_msvc
) >"$failure_log" 2>&1; then
    cat "$failure_log" >&2
    fail "unavailable-interpreter stub is not eagerly fetchable"
fi

# build_config must not affect the free-threaded axis: the hub still registers
# free-threaded toolchains alongside the debug-full default mode.
if ! (
    cd "$case_dir/root-debug-full-build-config" &&
        "$BAZEL" query --lockfile_mode=off -- '@python_interpreters//:*'
) >"$failure_log" 2>&1; then
    cat "$failure_log" >&2
    fail "querying the toolchain hub failed"
fi
if ! grep -Fq "python_3_13_x86_64_unknown_linux_gnu_freethreaded" "$failure_log"; then
    cat "$failure_log" >&2
    fail "debug-full hub does not register free-threaded toolchains"
fi

# Tokens in canonical order matter: manifests publish "pgo+lto-full", never
# "lto+pgo-full", so the misordered spelling must be rejected at parse time
# rather than silently matching zero assets.
expect_failure \
    root-misordered-build-config \
    "Unrecognized PBS build_config 'lto+pgo-full'"
expect_failure \
    root-static-build-config \
    "build_config 'lto+static-full' selects a statically linked libpython"
expect_failure \
    root-freethreaded-build-config \
    "build_config 'freethreaded+pgo+lto-full' must not select free-threading"
# "debug+lto-full" parses (tokens are in canonical order) but PBS never
# publishes it, so no platform matches. 3.13's free-threaded archives must not
# mask the empty default mode, and the failure must point at build_config as
# the likely cause, not only at the release list.
expect_failure \
    root-unmatched-build-config \
    "No CPython 3.13 'debug+lto-full' archives found for any platform"
expect_failure \
    root-unmatched-build-config \
    "PBS publishes build_config 'debug+lto-full' only for some version/platform combinations"

echo "PASS: build_config provisions -full runtimes and is validated with actionable errors"
