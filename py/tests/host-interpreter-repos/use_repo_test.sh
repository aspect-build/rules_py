#!/usr/bin/env bash
set -euo pipefail

module="$1"
versions="$2"

status=0
for platform in $(awk '/^PLATFORMS = \{/,/^\}/' "$versions" | sed -n 's/^    "\([^"]*\)": {$/\1/p'); do
    repo="python_3_13_${platform//-/_}"
    if ! grep -q "^    \"$repo\",$" "$module"; then
        echo "MODULE.bazel use_repo is missing \"$repo\"" >&2
        status=1
    fi
done
exit "$status"
