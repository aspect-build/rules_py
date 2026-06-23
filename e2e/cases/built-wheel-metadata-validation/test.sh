#!/usr/bin/env bash
#
# Module-extension validation for built-wheel metadata. Invalid cases live in
# nested modules so their expected failures do not poison e2e/MODULE.bazel.
set -euo pipefail

# Resolve runfile symlinks so local_path_override reaches the source checkout.
readonly SOURCE_CASE_DIR="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
readonly RULES_PY_ROOT="$(cd "${SOURCE_CASE_DIR}/../../.." && pwd)"
readonly BAZEL="${BAZEL:-bazel}"

if [[ -n "${TEST_TMPDIR:-}" ]]; then
    CASE_DIR="${TEST_TMPDIR}/built-wheel-metadata-validation"
else
    CASE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/built-wheel-metadata-validation.XXXXXX")"
    trap 'rm -rf "${CASE_DIR}"' EXIT
fi
readonly CASE_DIR

mkdir -p "${CASE_DIR}"
for case_name in \
    all-empty-declaration \
    bdist-only-declaration \
    casefold-console-script \
    custom-build-file-content \
    directory-subset \
    duplicate-console-script \
    duplicate-top-level \
    malformed-console-script \
    matching-sdist \
    matching-source-build \
    mismatched-source-build; do
    cp -R "${SOURCE_CASE_DIR}/${case_name}" "${CASE_DIR}/${case_name}"
    sed \
        -e "s|__RULES_PY_ROOT__|${RULES_PY_ROOT}|g" \
        -e "s|__CONFIGURE_SCRIPT__|${CASE_DIR}/${case_name}/configure.sh|g" \
        "${CASE_DIR}/${case_name}/MODULE.bazel.in" \
        >"${CASE_DIR}/${case_name}/MODULE.bazel"
    rm "${CASE_DIR}/${case_name}/MODULE.bazel.in"
    if [[ -f "${CASE_DIR}/${case_name}/BUILD.bazel.in" ]]; then
        mv "${CASE_DIR}/${case_name}/BUILD.bazel.in" \
            "${CASE_DIR}/${case_name}/BUILD.bazel"
    fi
    case "${case_name}" in
        bdist-only-declaration)
            mkdir "${CASE_DIR}/${case_name}/fixture"
            cp \
                "${SOURCE_CASE_DIR}/../uv-no-sdist-754/pyproject.toml" \
                "${SOURCE_CASE_DIR}/../uv-no-sdist-754/uv.lock" \
                "${CASE_DIR}/${case_name}/fixture/"
            ;;
        all-empty-declaration | custom-build-file-content | matching-sdist | matching-source-build | mismatched-source-build)
            mkdir "${CASE_DIR}/${case_name}/fixture"
            cp "${SOURCE_CASE_DIR}/../uv-sdist-fallback/uv.lock" \
                "${CASE_DIR}/${case_name}/fixture/uv.lock"
            ;;
    esac
done

stderr_log="${CASE_DIR}/stderr.log"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

expect_failure() {
    local case_name="$1"
    local expected_diagnostic="$2"

    echo "== ${case_name} must fail during extension evaluation =="
    if (cd "${CASE_DIR}/${case_name}" && "${BAZEL}" query --lockfile_mode=off '@validation//...') \
        >/dev/null 2>"$stderr_log"; then
        cat "$stderr_log" >&2
        fail "expected ${case_name} to fail, but it succeeded"
    fi
    if ! grep -Fq -- "$expected_diagnostic" "$stderr_log"; then
        cat "$stderr_log" >&2
        fail "${case_name} did not report: ${expected_diagnostic}"
    fi
    echo "PASS: ${case_name} reported the expected diagnostic"
}

expect_failure \
    "duplicate-console-script" \
    'duplicate console script names: ["metadata-tool"]'
expect_failure \
    "casefold-console-script" \
    'duplicate console script names: ["metadata-tool"]'
expect_failure \
    "duplicate-top-level" \
    'duplicate top_levels entries: ["metadata_package"]'
expect_failure \
    "directory-subset" \
    'directory_top_levels entries are absent from top_levels: ["other"]'
expect_failure \
    "malformed-console-script" \
    'console_scripts entries must use name=module:function'
for malformed_script in \
    'extra-colon=metadata.main:run:extra' \
    'extra-equals=metadata=main:run' \
    'extra=metadata.main:run[feature]'; do
    if ! grep -Fq -- "$malformed_script" "$stderr_log"; then
        cat "$stderr_log" >&2
        fail "malformed-console-script accepted ${malformed_script}"
    fi
done
expect_failure \
    "bdist-only-declaration" \
    'uv.built_wheel_metadata() declarations do not match lock records with source distributions:'
if ! grep -Fq -- ':uv.lock:pywin32==311' "$stderr_log"; then
    cat "$stderr_log" >&2
    fail "bdist-only-declaration did not identify the unused lock record"
fi
echo "== custom-build-file-content must reject bypassed metadata =="
if (cd "${CASE_DIR}/custom-build-file-content" && \
    "${BAZEL}" query --lockfile_mode=off \
        '@sdist_build__uv_sdist_fallback__cowsay__6_0//:whl') \
    >/dev/null 2>"$stderr_log"; then
    cat "$stderr_log" >&2
    fail "expected custom-build-file-content to fail, but it succeeded"
fi
if ! grep -Fq -- \
    'returned build_file_content while built wheel metadata is configured' \
    "$stderr_log"; then
    cat "$stderr_log" >&2
    fail "custom-build-file-content did not report bypassed metadata"
fi
echo "PASS: custom-build-file-content rejected bypassed metadata"

echo "== all-empty-declaration must validate known-empty scripts =="
execution_log="${CASE_DIR}/execution.log"
if ! (cd "${CASE_DIR}/all-empty-declaration" && \
    "${BAZEL}" test --lockfile_mode=off --test_output=errors //:consume) \
    >"$execution_log" 2>&1; then
    cat "$execution_log" >&2
    fail "expected all-empty-declaration source build to succeed"
fi
aquery_log="${CASE_DIR}/all-empty.aquery"
if ! (cd "${CASE_DIR}/all-empty-declaration" && \
    "${BAZEL}" aquery --lockfile_mode=off \
        'mnemonic("WhlInstall", deps(//:consume))') \
    >"$aquery_log" 2>"$stderr_log"; then
    cat "$stderr_log" >&2
    fail "could not inspect all-empty-declaration install action"
fi
for expected_argument in \
    '--expected-metadata' \
    'console_scripts' \
    '--expected-metadata-origin' \
    'uv.built_wheel_metadata()'; do
    if ! grep -Fq -- "$expected_argument" "$aquery_log"; then
        cat "$aquery_log" >&2
        fail "all-empty-declaration action omitted ${expected_argument}"
    fi
done
echo "PASS: all-empty-declaration reached and validated the source-built wheel"

echo "== matching-source-build must validate a nonempty layout =="
if ! (cd "${CASE_DIR}/matching-source-build" && \
    "${BAZEL}" test --lockfile_mode=off --test_output=errors //:consume) \
    >"$execution_log" 2>&1; then
    cat "$execution_log" >&2
    fail "expected matching-source-build to succeed"
fi
echo "PASS: matching-source-build validated the declared layout and scripts"

echo "== mismatched-source-build must fail during wheel installation =="
if (cd "${CASE_DIR}/mismatched-source-build" && \
    "${BAZEL}" test --lockfile_mode=off --test_output=errors //:consume) \
    >"$execution_log" 2>&1; then
    cat "$execution_log" >&2
    fail "expected mismatched-source-build to fail, but it succeeded"
fi
for expected_diagnostic in \
    'uv.built_wheel_metadata() for lock' \
    'fixture//:uv.lock' \
    'cowsay==6.0' \
    'expected {"console_scripts": ["cowsay-tool=cowsay.__main__:cli"]}' \
    'actual {"console_scripts": ["cowsay=cowsay.__main__:cli"]}'; do
    if ! grep -Fq -- "$expected_diagnostic" "$execution_log"; then
        cat "$execution_log" >&2
        fail "mismatched-source-build did not report: ${expected_diagnostic}"
    fi
done
echo "PASS: mismatched-source-build reported the public declaration mismatch"

echo "== matching-sdist must succeed without forcing no-binary =="
if ! (cd "${CASE_DIR}/matching-sdist" && "${BAZEL}" query --lockfile_mode=off '@validation//cowsay') \
    >/dev/null 2>"$stderr_log"; then
    cat "$stderr_log" >&2
    fail "expected matching-sdist extension evaluation to succeed"
fi
echo "PASS: matching wheel and optional sdist consumed the declaration"
