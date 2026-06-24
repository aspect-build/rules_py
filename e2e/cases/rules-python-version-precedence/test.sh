#!/usr/bin/env bash
#
# This checks the public build-wide alias and both projects' target-specific
# transitions, so CI runs it directly with the required flag.
set -uo pipefail

case_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$case_dir/../.." || exit 1  # e2e workspace root

BAZEL="${BAZEL:-bazel}"
BUILD_WIDE_VERSION="--@aspect_rules_py//py:python_version=3.12.9"
LOCAL_VERSION="--@aspect_rules_py//py:python_version=3.13.1"

if ! "$BAZEL" test \
    "$BUILD_WIDE_VERSION" \
    -- \
    //cases/rules-python-version-precedence:aspect_attribute \
    //cases/rules-python-version-precedence:aspect_no_attribute \
    //cases/rules-python-version-precedence:rules_python_attribute; then
    echo "FAIL: Python rules did not share one version setting" >&2
    exit 1
fi

local_mismatch_files="$(cd "$case_dir/local" && "$BAZEL" cquery \
    "$BUILD_WIDE_VERSION" \
    --output=files \
    -- //:local_version_matches)" || {
    echo "FAIL: the local interpreter mismatch case did not analyze" >&2
    exit 1
}
case "$local_mismatch_files" in
    *local_selected.txt*)
        echo "FAIL: the local interpreter matched a different version" >&2
        exit 1
        ;;
esac

local_match_files="$(cd "$case_dir/local" && "$BAZEL" cquery \
    "$LOCAL_VERSION" \
    --output=files \
    -- //:local_version_matches)" || {
    echo "FAIL: the local interpreter match case did not analyze" >&2
    exit 1
}
case "$local_match_files" in
    *local_selected.txt*) ;;
    *)
        echo "FAIL: the local interpreter did not match the public version alias" >&2
        exit 1
        ;;
esac

echo "PASS: Python rules share one version setting"
