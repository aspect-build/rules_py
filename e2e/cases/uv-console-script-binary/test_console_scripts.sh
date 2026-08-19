#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$TEST_SRCDIR/_main/uv-console-script-binary" && pwd)"
DEFAULT_BIN="${DIR}/whoowns"
EXPLICIT_BIN="${DIR}/whoowns_explicit"
KWARGS_BIN="${DIR}/whoowns_kwargs"
MKDOCS_BIN="${DIR}/mkdocs"

for bin in "${DEFAULT_BIN}" "${EXPLICIT_BIN}" "${KWARGS_BIN}" "${MKDOCS_BIN}"; do
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

# The kwargs target passes python_version (py_binary-specific) and tags;
# it existing and running at all is the regression assertion — forwarding
# python_version to the internal genrule was a load-time error.
kwargs_out="$("${KWARGS_BIN}" --help 2>&1)"
if [[ -z "${kwargs_out}" ]]; then
    echo "FAIL: kwargs console script produced no help output" >&2
    exit 1
fi

# `--strict` makes mkdocs fail if the gh-admonitions plugin (provided only via
# the `deps` attribute) cannot be discovered through entry points.
SITE="${TEST_TMPDIR}/site"
"${MKDOCS_BIN}" build --strict -f "${DIR}/mkdocs.yml" -d "${SITE}"

if ! grep -q 'class="admonition note"' "${SITE}/index.html"; then
    echo "FAIL: plugin-rendered admonition missing from generated site" >&2
    exit 1
fi

echo "PASS: console script binaries executed and mkdocs discovered the plugin from deps"
