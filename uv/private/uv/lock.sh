#!/usr/bin/env sh

if [ -e "pyproject.toml" ]; then
    proj=$(realpath ./pyproject.toml)
else
    proj=$(realpath $(dirname $0)/pyproject.toml)
fi

dir=$(mktemp -d)
cp $proj $dir/
bazel run @multitool//tools/uv:uv -- add --directory=$dir --no-workspace "$@"
bazel run @multitool//tools/uv:uv -- lock --directory=$dir
cp $dir/uv.lock .
rm -r $dir
