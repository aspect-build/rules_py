#!/usr/bin/env bash
set -euo pipefail

query_output="$1"
expected="$2"

grep -Fx -- "$expected" "$query_output"
