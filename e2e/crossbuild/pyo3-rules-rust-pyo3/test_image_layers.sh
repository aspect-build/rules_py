#!/usr/bin/env bash
# Docker-free check of the OCI layers: every layer extracted into one root
# must yield a runnable /app (py_image_layer's root is the launcher) whose runfiles carry the PyO3 extension and
# whose interpreter can load it.
set -euo pipefail

root="${TEST_TMPDIR}/root"
mkdir -p "${root}"
listing="${TEST_TMPDIR}/listing.txt"
: > "${listing}"
for layer in "$@"; do
    tar -tf "${layer}" >> "${listing}"
    tar -xf "${layer}" -C "${root}"
done

if ! grep -q 'pyo3_ext_rr\.so$' "${listing}"; then
    echo "FAIL: no layer ships pyo3_ext_rr.so"
    cat "${listing}"
    exit 1
fi

# The test runner's RUNFILES_DIR points at this script's runfiles; the image
# sets RUNFILES_DIR=/app.runfiles for the same launcher, so do the same here.
out="$(RUNFILES_DIR="${root}/app.runfiles" "${root}/app" 2>&1)" || {
    echo "FAIL: /app exited non-zero: ${out}"
    exit 1
}
[[ "${out}" == "5" ]] || { echo "FAIL: expected 5, got: ${out}"; exit 1; }
echo "PASS: pyo3_ext_rr.so shipped in a layer and loaded by the image's interpreter"
