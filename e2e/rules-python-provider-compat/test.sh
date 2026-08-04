#!/usr/bin/env bash

# `//...` covers the compatibility layer turned on (see .bazelrc). This asserts
# the other half: with the layer off, an @rules_python consumer of a
# rules_py library fails analysis, so the passing tests above prove the flag
# and not some incidental interop.

set -uo pipefail

cd "$(dirname "$0")" || exit 1

BAZEL="${BAZEL:-bazel}"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

failure_log="$(mktemp)"
trap 'rm -f "$failure_log"' EXIT

if "$BAZEL" build \
    --lockfile_mode=off \
    --@aspect_rules_py//py:emit_rules_python_providers=false \
    -- //:rules_python_consumer_test >"$failure_log" 2>&1; then
    fail "a rules_python target consumed a rules_py library without the compatibility layer"
fi

if ! grep -q "does not have mandatory providers" "$failure_log"; then
    cat "$failure_log" >&2
    fail "the disabled compatibility layer lacked a provider-mismatch diagnostic"
fi

echo "PASS: rules_python providers are emitted only under the compatibility flag"
