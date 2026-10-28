#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
BAZEL="${BAZEL:-bazel}"
# The default Bazel 8 lane verifies the unchanged, unscoped mode below.
module_file=$(cat MODULE.bazel)
bindings_file=$(cat bindings/BUILD.bazel)
trap 'printf "%s\n" "$module_file" > MODULE.bazel; printf "%s\n" "$bindings_file" > bindings/BUILD.bazel' EXIT

# Default behavior, without reading a project file, works on supported Bazel 8/9.
"$BAZEL" build --lockfile_mode=off --@aspect_rules_py//py:python_version=3.10 \
    //bindings:check311 //bindings:check312
if [[ "$("$BAZEL" info release)" == *"release 8."* ]]; then
    exit 0
fi
printf '%s\nconfig.python_version_scope(scope = "project")\n' "$module_file" > MODULE.bazel
sed 's/native_version = "inherit"/native_version = "3.10"/g' <<< "$bindings_file" > bindings/BUILD.bazel
"$BAZEL" build --lockfile_mode=off --@aspect_rules_py//py:python_version=3.10 \
    //bindings:check311 //bindings:check312
# Two transitioned bindings must configure the native dependency only once.
configs=$("$BAZEL" cquery --lockfile_mode=off --@aspect_rules_py//py:python_version=3.10 \
    'filter("native:core", deps(set(//bindings:check311 //bindings:check312)))' --output=label)
[[ "$(printf '%s\n' "$configs" | wc -l | tr -d ' ')" == 1 ]]
printf '\nconfig.python_version_scope(scope = "project")\n' >> MODULE.bazel
log=$(mktemp)
trap 'rm -f "$log"; printf "%s\n" "$module_file" > MODULE.bazel; printf "%s\n" "$bindings_file" > bindings/BUILD.bazel' EXIT
if "$BAZEL" build --lockfile_mode=off //bindings:check311 > "$log" 2>&1; then
    echo "Duplicate configuration unexpectedly succeeded" >&2
    exit 1
fi
grep -F "python_version_scope may only be configured once" "$log"
