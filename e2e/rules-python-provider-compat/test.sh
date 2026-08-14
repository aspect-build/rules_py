#!/usr/bin/env bash

# `//...` covers the compatibility layer turned on (see .bazelrc). This asserts
# the other half: with the layer off, an @rules_python consumer of a
# rules_py library or binary fails analysis, so the passing tests above prove
# the flag and not some incidental interop.

set -uo pipefail

cd "$(dirname "$0")" || exit 1

BAZEL="${BAZEL:-bazel}"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

failure_log="$(mktemp)"
trap 'rm -f "$failure_log"' EXIT

for target in //:rules_python_consumer_test //:rules_python_binary_consumer_test; do
    if "$BAZEL" build \
        --lockfile_mode=off \
        --@aspect_rules_py//py:emit_rules_python_providers=false \
        -- "$target" >"$failure_log" 2>&1; then
        fail "a rules_python target consumed $target's rules_py dependency without the compatibility layer"
    fi

    if ! grep -q "does not have mandatory providers" "$failure_log"; then
        cat "$failure_log" >&2
        fail "the disabled compatibility layer lacked a provider-mismatch diagnostic for $target"
    fi
done

echo "PASS: rules_python providers are emitted only under the compatibility flag"
