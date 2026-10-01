#!/usr/bin/env bash
# Check that a native extension .so inside a tar has the correct platform
# suffix in its filename — i.e. EXT_SUFFIX and SOABI reflect the target
# platform, not the exec host.
#
# Usage: check_so_suffix.sh <tar_file> <so_path_grep_pattern> <expected_suffix_substring>
#   so_path_grep_pattern: grep -E pattern matching the .so's full path inside
#     the tar, specific enough to pick exactly one .so if the tar bundles
#     more than the package under test (e.g. a reference build for diffing).
set -euo pipefail

tar_file="${1:?usage: check_so_suffix.sh <tar_file> <so_path_grep_pattern> <expected_suffix>}"
so_pattern="${2:?so path grep pattern}"
expected="${3:?expected suffix substring, e.g. cpython-312-x86_64-linux-gnu}"

so_name=$(tar tf "$tar_file" | grep -E "$so_pattern" | head -1)
if [ -z "$so_name" ]; then
    echo "FAIL: no .so matching '$so_pattern' in tar $tar_file"
    exit 1
fi

echo ".so: $so_name"

if ! echo "$so_name" | grep -q "$expected"; then
    echo "FAIL: expected suffix '$expected' not found in filename"
    exit 1
fi

echo "PASS: $so_name contains '$expected'"
