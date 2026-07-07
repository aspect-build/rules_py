#!/usr/bin/env bash
# Build the generated API docs archive attached to each release, see
# https://github.com/bazelbuild/bazel-central-registry/blob/main/docs/stardoc.md
set -o errexit -o nounset -o pipefail

docs="$(mktemp -d)"
targets="$(mktemp)"
out=$1
bazel --output_base="$docs" query --output=label --output_file="$targets" 'kind("starlark_doc_extract rule", //py/... + //uv/...)'
if [ ! -s "$targets" ]; then
    echo "ERROR: no starlark_doc_extract targets found; the release docs archive would be empty" >&2
    exit 1
fi
bazel --output_base="$docs" build --target_pattern_file="$targets"
tar --create --auto-compress \
    --directory "$(bazel --output_base="$docs" info bazel-bin)" \
    --file "${out}" .
