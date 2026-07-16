#!/usr/bin/env bash
#
# Runs the py_console_script_binary produced by rules_python's entry-point
# machinery on this module's rules_py-provisioned toolchain.
set -euo pipefail

out="$("$1" moo-from-rules-py)"
case "$out" in
    *moo-from-rules-py*) echo "OK" ;;
    *)
        echo "FAIL: unexpected output:" >&2
        echo "$out" >&2
        exit 1
        ;;
esac
