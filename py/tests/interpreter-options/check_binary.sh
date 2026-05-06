#!/usr/bin/env bash
# Run the py_binary launcher; the script's own assert will fail if
# `interpreter_options = ["-O"]` didn't reach `python -O main.py`.
set -euo pipefail

ROOT="$(dirname "$0")"
"$ROOT"/bin_O
