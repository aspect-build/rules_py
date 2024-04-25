#!/usr/bin/env bash

set -o errexit -o pipefail -o nounset

OS="$(uname | tr '[:upper:]' '[:lower:]')"
ARCH="$(arch)"
ALLOWED="rules_py_tools.${OS}_${ARCH}"
if [ "$ARCH" == "x86_64" ]; then
    ALLOWED="rules_py_tools.${OS}_amd64"
fi

# This test references pre-built artifacts from a prior release.
# Will need to bump this version in the future when there are breaking changes.
export RULES_PY_RELEASE_VERSION=0.7.1

#############
# Test bzlmod
(
    cd ../..
    patch -p1 < .bcr/patches/*.patch
)
OUTPUT_BASE=$(mktemp -d)
output=$(bazel "--output_base=$OUTPUT_BASE" run --enable_bzlmod //:main)
if [[ "$output" != "hello world" ]]; then
  >&2 echo "ERROR: bazel command did not produce expected output"
  exit 1
fi
externals=$(ls $OUTPUT_BASE/external)

if echo "$externals" | grep -v "${ALLOWED}" | grep -v ".marker" | grep rules_py_tools.
then
    >&2 echo "ERROR: rules_py binaries were fetched for platform other than ${ALLOWED}"
    exit 1
fi
if echo "$externals" | grep rust
then
    >&2 echo "ERROR: we fetched a rust repository"
    exit 1
fi

#############
# Test WORKSPACE
OUTPUT_BASE=$(mktemp -d)
output=$(bazel "--output_base=$OUTPUT_BASE" run --noenable_bzlmod //:main)
if [[ "$output" != "hello world" ]]; then
  >&2 echo "ERROR: bazel command did not produce expected output"
  exit 1
fi

externals=$(ls $OUTPUT_BASE/external)

if echo "$externals" | grep -v "${ALLOWED}" | grep -v ".marker" | grep rules_py_tools.
then
    >&2 echo "ERROR: rules_py binaries were fetched for platform other than ${ALLOWED}"
    exit 1
fi
if echo "$externals" | grep rust
then
    >&2 echo "ERROR: we fetched a rust repository"
    exit 1
fi
