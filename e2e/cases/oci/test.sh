#!/usr/bin/env bash
#
# Multi-binary destination collisions are discovered by the validation action,
# so the expected-failure case cannot be an sh_test under //....
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

BAZEL="${BAZEL:-bazel}"
PKG="//oci/py_image_layer"
output_log="$(mktemp)"
trap 'rm -f "$output_log"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

expect_diagnostic() {
    if ! grep -Fq "$1" "$output_log"; then
        cat "$output_log" >&2
        fail "expected validation diagnostic: $1"
    fi
}

expect_listing_count() {
    local listing="$1"
    local suffix="$2"
    local expected="$3"
    local actual
    actual="$(awk -v suffix="$suffix" 'substr($0, length($0) - length(suffix) + 1) == suffix { count++ } END { print count + 0 }' "$listing")"
    if test "$actual" -ne "$expected"; then
        cat "$listing" >&2
        fail "$suffix: expected $expected, found $actual"
    fi
}

echo "== versioned wheel children must share an image when destinations agree =="
if ! "$BAZEL" build --output_groups=_validation -- \
    "${PKG}:_configured_pure_wheel_layers" \
    "${PKG}:_configured_wheel_collision_layers" >"$output_log" 2>&1; then
    cat "$output_log" >&2
    fail "expected the two-version wheel images to validate"
fi

echo "== remapped destinations must fail validation =="
if "$BAZEL" build --keep_going --output_groups=_validation -- \
    "${PKG}:_scalar_launcher_collision_layers" \
    "${PKG}:_scalar_strip_collision_layers" \
    "${PKG}:_scalar_root_collision_layers" >"$output_log" 2>&1; then
    cat "$output_log" >&2
    fail "expected remapped destinations to fail validation"
fi
expect_diagnostic "py_image_layer runfile collision at ./app/bin/_scalar_launcher_collision:"
expect_diagnostic "py_image_layer runfile collision at ./app.runfiles/_main/oci/py_image_layer/_scalar_strip_collision/data.txt:"
expect_diagnostic "py_image_layer runfile collision at ./app.runfiles/_main/oci/py_image_layer/server.py:"

echo "PASS: expanded and remapped destinations validate correctly"

echo "== source closures must preserve scalar and shared layouts =="
if ! "$BAZEL" build -- \
    "${PKG}:_scalar_default_sources_listing" \
    "${PKG}:my_app_shared_sources_listing" >"$output_log" 2>&1; then
    cat "$output_log" >&2
    fail "expected source-layer listings to build"
fi
listing="bazel-bin/oci/py_image_layer/_scalar_default_sources.listing"
expect_listing_count "$listing" "/app" 2
expect_listing_count "$listing" "/app/config.json" 2
if grep -Fq './app.runfiles/_main/oci/py_image_layer/my_app_peer_bin/config.json' "$listing"; then
    cat "$listing" >&2
    fail "scalar executable descendant leaked into the shared runfiles layout"
fi
listing="bazel-bin/oci/py_image_layer/_my_app_shared_sources.listing"
for suffix in \
    /branding/__init__.py \
    /branding/palette.txt \
    /lib/python3.11/os.py \
    /custom/bin/my_app_bin \
    /custom/bin/my_app_peer_bin \
    /oci/py_image_layer/my_app_peer_bin/config.json; do
    expect_listing_count "$listing" "$suffix" 1
done

echo "PASS: scalar and shared source layouts are preserved"

if [[ "${USE_BAZEL_VERSION:-}" != 9* ]]; then
    echo "== nested launcher prefixes must share the same runfiles layout in either input order =="
    if ! "$BAZEL" build -- "${PKG}:_nested_prefix_sources_listing" >"$output_log" 2>&1; then
        cat "$output_log" >&2
        fail "expected the nested launcher source layers to build"
    fi
    listing="bazel-bin/oci/py_image_layer/_nested_prefix_sources.listing"
    expect_listing_count "$listing" "/app.runfiles/_main/nested/data.txt" 2
    if grep -Fq './app.runfiles/worker.runfiles/' "$listing"; then
        cat "$listing" >&2
        fail "nested launcher prefix leaked into the shared runfiles layout"
    fi
    echo "PASS: nested launcher prefixes share the same runfiles layout"
fi
