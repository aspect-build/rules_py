#!/usr/bin/env bash
# An unpinned Python terminal must not put its native deps in a second target
# configuration. The native library is requested directly and through py_binary;
# both paths must share one CppCompile action.
set -euo pipefail

cd "$(dirname "$0")/.."

BAZEL="${BAZEL:-bazel}"
count="$($BAZEL aquery --lockfile_mode=off 'mnemonic(CppCompile, //noop-default-transition:native_dep + //noop-default-transition:unversioned)' | grep -c '^  Mnemonic: CppCompile$')"

test "$count" -eq 1
