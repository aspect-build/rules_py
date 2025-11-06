#!/usr/bin/env sh

if [ -e "pyproject.toml" ]; then
    proj=$(realpath ./pyproject.toml)
else
    proj=$(realpath $(dirname $0)/pyproject.toml)
fi

dir=$(mktemp -d)
cp $proj $dir/
uv add --directory=$dir --no-workspace "$@"
uv lock --directory=$dir
cp $dir/uv.lock .
rm -r $dir
