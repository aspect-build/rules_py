#!/usr/bin/env bash
set -euo pipefail

# Usage: apply_patches.sh <patch_strip> <src_dir> <out_dir> [--compile-pyc <python>] <patch1> [patch2 ...]
#
# Copies src_dir into out_dir and applies each patch file in order.
# If --compile-pyc <python> is given, runs compileall after patching.

PATCH_STRIP="$1"; shift
SRC_DIR="$1"; shift
OUT_DIR="$1"; shift

COMPILE_PYC=""
PYTHON=""
if [[ "${1:-}" == "--compile-pyc" ]]; then
    COMPILE_PYC=1
    shift
    PYTHON="$1"; shift
fi

cp -rL "${SRC_DIR}/." "${OUT_DIR}/"

for patch_file in "$@"; do
    patch -p"${PATCH_STRIP}" -d "${OUT_DIR}" < "${patch_file}"
done

if [[ -n "${COMPILE_PYC}" ]]; then
    "${PYTHON}" -m compileall -q --invalidation-mode unchecked-hash "${OUT_DIR}" || \
        echo "WARNING: compileall failed (non-fatal)" >&2
fi
