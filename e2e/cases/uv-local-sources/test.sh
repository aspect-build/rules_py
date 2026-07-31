#!/usr/bin/env bash
# The uv module extension reads local archives before Bazel can run a genrule.
# Generate them in a temporary workspace so real source-path coverage does not
# require committing binary blobs or leaving setuptools egg-info in the tree.
set -euo pipefail

fixture_dir="$(cd "$(dirname "$0")" && pwd)"
rules_py_root="$(cd "$fixture_dir/../../.." && pwd)"
workspace="$(mktemp -d "${TMPDIR:-/tmp}/rules-py-uv-local-sources.XXXXXX")"
trap 'rm -rf "$workspace"' EXIT

python3 "$fixture_dir/generate_artifacts.py" "$workspace" "$rules_py_root"

cd "$workspace"
"${BAZEL:-bazel}" test --lockfile_mode=off //:all
