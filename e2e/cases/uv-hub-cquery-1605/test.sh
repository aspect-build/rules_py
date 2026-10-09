#!/usr/bin/env bash
#
# A hub alias is incompatible outside its dep_groups, but cquery's proto and
# BUILD outputs still print its attributes. `actual` must resolve there too, or
# Bazel crashes on the unmatched select(). With no dep_group set, every
# @pypi_multi alias is outside its groups.
set -euo pipefail

cd "$(dirname "$0")/.."  # e2e/cases workspace root

BAZEL="${BAZEL:-bazel}"

for output in proto build; do
    "$BAZEL" cquery \
        --lockfile_mode=off \
        --output="${output}" \
        -- "@pypi_multi//cowsay + @pypi_multi//cowsay:whl" >/dev/null
done
