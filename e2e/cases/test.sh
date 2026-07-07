#!/usr/bin/env bash
#
# Script-driven checks for the shared `cases/` workspace.
#
# A few cases can't be an `sh_test` under `//...` — they assert a build
# *failure* or need a real top-level `bazel run`. Each ships a
# `cases/<case>/test.sh`; this aggregator runs them all so CI only has to
# discover one entrypoint per workspace via `e2e/*/test.sh`.
#
# Override bazel with $BAZEL. Each sub-script self-locates, so cwd here only
# needs to make the `*/test.sh` glob resolve.
set -uo pipefail

cd "$(dirname "$0")" || exit 1  # e2e/cases

status=0
for script in */test.sh; do
    # Skip bazel's convenience symlinks (bazel-bin, bazel-cases, …); after
    # `bazel test //...` runs, bazel-cases/test.sh resolves into the output tree
    # and re-invoking bazel from there is an error.
    case "${script}" in bazel-*/test.sh) continue ;; esac
    echo "::group::${script}"
    if bash "${script}"; then
        echo "PASS: ${script}"
    else
        echo "FAIL: ${script}"
        status=1
    fi
    echo "::endgroup::"
done
exit "${status}"
