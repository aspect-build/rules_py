#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
"${BAZEL:-bazel}" build --lockfile_mode=error --@pypi_single//dep_group=single_project_hub -- @project__single_project_hub//private/sccs:all
