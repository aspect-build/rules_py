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
repo_root="$(git -C . rev-parse --show-toplevel)"
trap 'rm -rf "$scratch"; git -C "$repo_root" checkout -- e2e/crossbuild/pycross-tiktoken/Cargo.lock' EXIT

"$BAZEL" run @sdist_build__pycross_tiktoken__tiktoken__0_13_0//:cargo_lock -- "$scratch/Cargo.lock"

lock="$scratch/Cargo.lock"
grep -q '^version = 4$' "$lock" || { echo "FAIL: not a Cargo.lock: $lock" >&2; exit 1; }
grep -q '^name = "tiktoken"$' "$lock" || { echo "FAIL: the root crate is missing from $lock" >&2; exit 1; }
grep -q 'source = "registry+https://github.com/rust-lang/crates.io-index"' "$lock" || { echo "FAIL: no crates.io dependency resolved in $lock" >&2; exit 1; }
echo "generated lock pins $(grep -c '^\[\[package\]\]' "$lock") packages"

# A lock regenerated in place must re-vendor: same file, same label, new
# contents. Bazel 9 stopped watching repository_ctx.path(label), and the
# configure tool reads the lock through its context JSON, so the watch in
# sdist_build is what makes the repository follow the file.
vendored_crates="@sdist_build__pycross_tiktoken__tiktoken__0_13_0//:vendored_crates"
external="$(bazel info output_base)/external"
vendor_dir="$(echo "$external"/*sdist_build__pycross_tiktoken__tiktoken__0_13_0/vendor)"

"$BAZEL" build "$vendored_crates"
[ ! -d "$vendor_dir/cfg-if-1.0.0" ] || { echo "FAIL: cfg-if vendored before the lock pins it" >&2; exit 1; }

# A real crates.io crate the lock does not pin, with its immutable checksum.
cat >> "$PWD/pycross-tiktoken/Cargo.lock" << 'EOF'

[[package]]
name = "cfg-if"
version = "1.0.0"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "baf1de4339761588bc0619e3cbc0120ee582ebb74b53b4efbf79117bd2da40fd"
EOF

"$BAZEL" build "$vendored_crates"
[ -d "$vendor_dir/cfg-if-1.0.0" ] || { echo "FAIL: the regenerated lock did not re-vendor" >&2; exit 1; }
echo "lock change at the same label re-vendored: cfg-if-1.0.0"

git -C "$repo_root" checkout -- e2e/crossbuild/pycross-tiktoken/Cargo.lock
"$BAZEL" build "$vendored_crates"
[ ! -d "$vendor_dir/cfg-if-1.0.0" ] || { echo "FAIL: reverting the lock kept the stale vendored crate" >&2; exit 1; }
echo "reverting the lock dropped it again"
