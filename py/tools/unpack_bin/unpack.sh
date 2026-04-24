#!/bin/bash
# Wheel unpacker replacing the Rust unpack_bin tool.
# Uses unzip (available on macOS and Linux) to extract wheel contents.
set -e

INTO=""
WHEEL=""
PY_MAJOR=""
PY_MINOR=""
PATCH_FILES=()
PATCH_STRIP=0
COMPILE_PYC=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --into)
      INTO="$2"
      shift 2
      ;;
    --wheel)
      WHEEL="$2"
      shift 2
      ;;
    --python-version-major)
      PY_MAJOR="$2"
      shift 2
      ;;
    --python-version-minor)
      PY_MINOR="$2"
      shift 2
      ;;
    --patch-strip)
      PATCH_STRIP="$2"
      shift 2
      ;;
    --patch)
      PATCH_FILES+=("$2")
      shift 2
      ;;
    --compile-pyc)
      COMPILE_PYC=true
      shift
      ;;
    --pyc-invalidation-mode)
      # Ignored for now; can be added if pre-compilation is enabled
      shift 2
      ;;
    --python)
      # Ignored for now; can be added if pre-compilation is enabled
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      shift
      ;;
  esac
done

if [[ -z "$INTO" || -z "$WHEEL" || -z "$PY_MAJOR" || -z "$PY_MINOR" ]]; then
  echo "Usage: $0 --into <dir> --wheel <file> --python-version-major <N> --python-version-minor <M>" >&2
  exit 1
fi

SITE_PACKAGES="$INTO/lib/python${PY_MAJOR}.${PY_MINOR}/site-packages"
mkdir -p "$SITE_PACKAGES"

# A wheel is a zip archive; extract directly into site-packages
unzip -q -o "$WHEEL" -d "$SITE_PACKAGES"

# Apply patches if any
for patch_file in "${PATCH_FILES[@]}"; do
  abs_patch="$(cd "$(dirname "$patch_file")" && pwd)/$(basename "$patch_file")"
  if [[ -f "$abs_patch" ]]; then
    patch -d "$INTO" -p"$PATCH_STRIP" -i "$abs_patch"
  else
    echo "ERROR: patch file not found: $patch_file (resolved: $abs_patch)" >&2
    exit 1
  fi
done

# Pre-compile .pyc if requested (best-effort using system python3)
if [[ "$COMPILE_PYC" == "true" ]]; then
  if command -v python3 &> /dev/null; then
    python3 -m compileall -q "$SITE_PACKAGES" || true
  fi
fi
