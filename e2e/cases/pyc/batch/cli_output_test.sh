#!/usr/bin/env bash
set -euo pipefail
test "$("$1" bazel)" = "*** Hello, BAZEL! (v1.0) ***"
