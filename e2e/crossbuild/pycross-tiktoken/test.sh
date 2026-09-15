#!/usr/bin/env bash
#
# Every Rust sdist_build repository carries a `:cargo_lock` target: `bazel run`
# resolves the sdist's crates with the project's own Rust toolchain and writes
# the lock into the workspace, the file `uv.override_package(cargo_lock = ...)`
# then vendors. tiktoken is the case that needs one — its sdist ships no lock —
# so regenerate it into a scratch path and check it is a real lock for that
# crate. It cannot be an sh_test: the target writes through
# BUILD_WORKSPACE_DIRECTORY and cargo reads the crates.io index over the
# network, which the action sandbox denies. crates.io moves, so the exact
# contents are not pinned; the checked-in Cargo.lock is what the build uses.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."  # e2e/crossbuild workspace root

BAZEL="${BAZEL:-bazel}"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

"$BAZEL" run @sdist_build__pycross_tiktoken__tiktoken__0_13_0//:cargo_lock -- "$scratch/Cargo.lock"

lock="$scratch/Cargo.lock"
grep -q '^version = 4$' "$lock" || { echo "FAIL: not a Cargo.lock: $lock" >&2; exit 1; }
grep -q '^name = "tiktoken"$' "$lock" || { echo "FAIL: the root crate is missing from $lock" >&2; exit 1; }
grep -q 'source = "registry+https://github.com/rust-lang/crates.io-index"' "$lock" || { echo "FAIL: no crates.io dependency resolved in $lock" >&2; exit 1; }
echo "generated lock pins $(grep -c '^\[\[package\]\]' "$lock") packages"
