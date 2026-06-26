#!/usr/bin/env bash
set -euo pipefail

if grep -Fq '"pre_build_patches":[' "$2" &&
    grep -Fq '"pre_build_patch_strip":1' "$2" &&
    grep -Fq 'noop.patch' "$2"; then
    printf '%s\n' '{"build_file_content":"filegroup(name = \"whl\", visibility = [\"//visibility:public\"])"}'
else
    printf '%s\n' '{"build_file_content":"fail(\"configure context lost pre-build patch settings\")"}'
fi
