#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$TEST_SRCDIR/_main/cases/uv-console-script-binary" && pwd)"
DEFAULT_BIN="${DIR}/whoowns"
EXPLICIT_BIN="${DIR}/whoowns_explicit"

for bin in "${DEFAULT_BIN}" "${EXPLICIT_BIN}"; do
    if [[ ! -x "${bin}" ]]; then
        echo "FAIL: expected executable binary at ${bin}" >&2
        exit 1
    fi
done

default_out="$("${DEFAULT_BIN}" --help 2>&1)"
explicit_out="$("${EXPLICIT_BIN}" --help 2>&1)"

if [[ -z "${default_out}" ]]; then
    echo "FAIL: default-name console script produced no help output" >&2
    exit 1
fi

if [[ -z "${explicit_out}" ]]; then
    echo "FAIL: explicit-script console script produced no help output" >&2
    exit 1
fi

echo "PASS: both console script binaries executed"
