#!/usr/bin/env bash
set -euo pipefail
test "$(env -u PYTHONOPTIMIZE "$1")" = "noop"
if out="$(PYTHONOPTIMIZE=1 "$1" 2>&1)"; then
    echo "expected a sourceless launcher to refuse PYTHONOPTIMIZE, got: $out" >&2
    exit 1
fi
case "$out" in
*"sourceless bytecode is level 0"*) ;;
*) echo "unexpected failure: $out" >&2; exit 1 ;;
esac
