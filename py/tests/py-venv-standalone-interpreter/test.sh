#!/usr/bin/env sh

set -ex

ROOT="$(dirname $0)"

"$ROOT"/.ex.venv/bin/python --help >/dev/null 2>&1

if [ "Hello, world!" != "$($ROOT/.ex.venv/bin/python -c 'from ex import hello; print(hello())')" ]; then
    exit 1
fi
