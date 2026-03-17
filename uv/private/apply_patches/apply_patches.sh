#!/usr/bin/env bash
set -euo pipefail

# Usage: apply_patches.sh [--python <interpreter>] <patch_strip> <src_dir> <out_dir> <patch1> [patch2 ...]
#
# Copies src_dir into out_dir and applies each patch file in order.
# If --python is provided, pre-compiles .py to .pyc bytecode after patching.

PYTHON=""
if [[ "$1" == "--python" ]]; then
    PYTHON="$2"; shift 2
fi

PATCH_STRIP="$1"; shift
SRC_DIR="$1"; shift
OUT_DIR="$1"; shift

cp -rL "${SRC_DIR}/." "${OUT_DIR}/"

for patch_file in "$@"; do
    patch -p"${PATCH_STRIP}" -d "${OUT_DIR}" < "${patch_file}"
done

# Pre-compile .py to .pyc bytecode — see install_wheel.sh for detailed rationale.
if [[ -n "${PYTHON}" ]]; then
    "${PYTHON}" -m compileall -q --invalidation-mode unchecked-hash "${OUT_DIR}" || \
        echo "warning: bytecode compilation failed" >&2
fi
