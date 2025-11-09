#!/usr/bin/env sh

set -ex

ROOT="$(dirname $0)"

"$ROOT"/.ex/bin/python --help

if [ "Hello, world!" != "$($ROOT/.ex/bin/python -c 'from ex import hello; print(hello())')" ]; then
    exit 1
fi
