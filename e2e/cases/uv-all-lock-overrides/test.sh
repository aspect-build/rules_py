#!/usr/bin/env bash
set -uo pipefail

case_dir="$(cd "$(dirname "$0")" && pwd)"
BAZEL="${BAZEL:-bazel}"
output_log="$(mktemp)"
trap 'rm -f "$output_log"' EXIT

expect_failure() {
    local fixture="$1"
    local repo="$2"
    local expected="$3"

    if (
        cd "$case_dir/$fixture" &&
            "$BAZEL" query --lockfile_mode=off -- "@$repo//:*"
    ) >"$output_log" 2>&1; then
        echo "FAIL: $fixture unexpectedly succeeded" >&2
        exit 1
    fi
    if ! grep -Fq "$expected" "$output_log"; then
        cat "$output_log" >&2
        echo "FAIL: $fixture did not report: $expected" >&2
        exit 1
    fi
}

for repo in \
    whl_install__implicit_version_alpha__boltons__25_0_0 \
    whl_install__implicit_version_beta__boltons__24_0_0; do
    if ! (
        cd "$case_dir/implicit-version" &&
            "$BAZEL" query --lockfile_mode=off --output=build -- "@$repo//:actual_install"
    ) >"$output_log" 2>&1; then
        cat "$output_log" >&2
        echo "FAIL: implicit-version could not inspect $repo" >&2
        exit 1
    fi
    if ! grep -Fq 'post_install.patch' "$output_log"; then
        cat "$output_log" >&2
        echo "FAIL: implicit-version did not apply the override to $repo" >&2
        exit 1
    fi
done

expect_failure target-all target_hub '`target` requires `lock`'
expect_failure zero-match zero_match_hub 'matches no uv.project() locks'
expect_failure ambiguous-version ambiguous_hub 'neither specifies a version nor has an implied singular version'
expect_failure duplicate duplicate_hub 'Duplicate uv.override_package() for package'

echo "PASS: all-lock overrides accept matching locks and reject invalid declarations"
