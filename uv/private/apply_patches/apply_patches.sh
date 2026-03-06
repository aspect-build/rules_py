#!/usr/bin/env bash
set -euo pipefail

# Usage: apply_patches.sh <patch_tool> <patch_strip> <src_dir> <out_dir> <patch1> [patch2 ...]
#
# Copies src_dir into out_dir and applies each patch file in order.

PATCH_TOOL="$1"; shift
PATCH_STRIP="$1"; shift
SRC_DIR="$1"; shift
OUT_DIR="$1"; shift

cp -r "${SRC_DIR}/." "${OUT_DIR}/"

for patch_file in "$@"; do
    "${PATCH_TOOL}" -p"${PATCH_STRIP}" -d "${OUT_DIR}" < "${patch_file}"
done
