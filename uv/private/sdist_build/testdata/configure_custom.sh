#!/usr/bin/env bash
set -euo pipefail

grep -Fq '"pre_build_patches":[' "$2"
grep -Fq '"pre_build_patch_strip":1' "$2"
grep -Fq 'noop.patch' "$2"
printf '%s\n' '{"build_file_content":"filegroup(name = \"whl\", srcs = [\"@aspect_rules_py//uv/private/sdist_build/testdata:fixture.whl\"], visibility = [\"//visibility:public\"])"}'
