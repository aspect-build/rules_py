#!/usr/bin/env bash
# Check that _geohash.so inside a py_image_layer tar has the correct platform
# suffix in its filename — i.e. EXT_SUFFIX and SOABI reflect the target
# platform, not the exec host.
#
# Usage: check_so_suffix.sh <tar_file> <expected_suffix_substring>
set -euo pipefail

tar_file="${1:?usage: check_so_suffix.sh <tar_file> <expected_suffix>}"
expected="${2:?expected suffix substring, e.g. cpython-312-x86_64-linux-gnu}"

so_name=$(tar tf "$tar_file" | grep '_geohash.*\.so$' | head -1)
if [ -z "$so_name" ]; then
    echo "FAIL: no _geohash*.so in tar $tar_file"
    exit 1
fi

echo ".so: $so_name"

if ! echo "$so_name" | grep -q "$expected"; then
    echo "FAIL: expected suffix '$expected' not found in filename"
    exit 1
fi

echo "PASS: $so_name contains '$expected'"
