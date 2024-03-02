#!/usr/bin/env bash

set -o errexit -o pipefail -o nounset

OUTPUT_BASE=$(mktemp -d)
# TODO: add a bzlmod test, requires a release first so the rust stuff is a dev_dependency
output=$(RULES_PY_RELEASE_VERSION=0.7.0 bazel "--output_base=$OUTPUT_BASE" run --noenable_bzlmod //:main)
if [[ "$output" != "hello world" ]]; then
  >&2 echo "ERROR: bazel command did not produce expected output"
  exit 1
fi

externals=$(ls $OUTPUT_BASE/external)
OS="$(uname | tr '[:upper:]' '[:lower:]')"
ARCH="$(arch)"

if echo "$externals" | grep -v "rules_py_tools.${OS}_${ARCH}" | grep -v ".marker" | grep rules_py_tools.
then
    >&2 echo "ERROR: binaries were fetched for too many platforms"
    exit 1
fi
if echo "$externals" | grep rust
then
    >&2 echo "ERROR: we fetched a rust repository"
    exit 1
fi
