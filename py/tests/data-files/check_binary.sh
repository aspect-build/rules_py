#!/usr/bin/env bash
# Run the py_binary launcher, passing the workspace-relative path that
# `args = ["$(location :data.txt)"]` would expand to under `bazel run`.
# read_data.py asserts the file is present in runfiles and readable.
set -euo pipefail

ROOT="$(dirname "$0")"
"$ROOT"/bin_data py/tests/data-files/data.txt
