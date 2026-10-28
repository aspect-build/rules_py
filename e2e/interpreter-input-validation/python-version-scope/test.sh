#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
BAZEL="${BAZEL:-bazel}"
module_file=$(cat MODULE.bazel)
bindings_file=$(cat bindings/BUILD.bazel)
trap 'printf "%s\n" "$module_file" > MODULE.bazel; printf "%s\n" "$bindings_file" > bindings/BUILD.bazel' EXIT

# Default behavior, without reading a project file.
"$BAZEL" build --lockfile_mode=off --@aspect_rules_py//py:python_version=3.10 \
    //bindings:check311 //bindings:check312
# Project scope requires Bazel 9.2 or later; the default Bazel 8 lane stops here.
if [[ "$("$BAZEL" info release)" == *"release 8."* ]]; then
    exit 0
fi
printf '%s\nconfig.python_version_scope(scope = "project")\n' "$module_file" > MODULE.bazel
sed 's/native_version = "inherit"/native_version = "3.10"/g' <<< "$bindings_file" > bindings/BUILD.bazel
"$BAZEL" build --lockfile_mode=off --@aspect_rules_py//py:python_version=3.10 \
    //bindings:check311 //bindings:check312
# Both bindings and the untransitioned path must give the native dependency the
# same rules_py settings. rules_python's version flag, which the transition also
# sets, needs rules_python's own opt-in, so it is not compared here.
settings=$("$BAZEL" cquery --lockfile_mode=off --@aspect_rules_py//py:python_version=3.10 \
    'filter("native:core", deps(set(//bindings:check311 //bindings:check312 //bindings:direct)))' \
    --output=starlark \
    --starlark:expr='sorted([(k, v) for k, v in build_options(target).items() if k.startswith("@@aspect_rules_py+//py/private/interpreter:")])')
[[ -n "$settings" && "$(printf '%s\n' "$settings" | sort -u | wc -l | tr -d ' ')" == 1 ]] || {
    printf 'Native dependency split by rules_py settings:\n%s\n' "$settings" >&2
    exit 1
}
printf '\nconfig.python_version_scope(scope = "project")\n' >> MODULE.bazel
log=$(mktemp)
trap 'rm -f "$log"; printf "%s\n" "$module_file" > MODULE.bazel; printf "%s\n" "$bindings_file" > bindings/BUILD.bazel' EXIT
if "$BAZEL" build --lockfile_mode=off //bindings:check311 > "$log" 2>&1; then
    echo "Duplicate configuration unexpectedly succeeded" >&2
    exit 1
fi
grep -F "python_version_scope may only be configured once" "$log"
