#!/usr/bin/env bash

set -o errexit -o pipefail -o nounset

OUTPUT_ROOT=$(mktemp -d)
bazel "--output_user_root=$OUTPUT_ROOT" query //...
if grep $(ls $OUTPUT_ROOT/external) -v "thing"
then
    >&2 echo "ERROR: binaries were fetched for too many platforms"
    exit 1
fi
