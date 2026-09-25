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

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir/.."  # e2e/crossbuild workspace root

BAZEL="${BAZEL:-bazel}"

scratch="$(mktemp -d)"
lock_fixture="$script_dir/Cargo.lock"
cp "$lock_fixture" "$scratch/Cargo.lock.fixture"
trap 'cp "$scratch/Cargo.lock.fixture" "$lock_fixture"; rm -rf "$scratch"' EXIT

"$BAZEL" run @sdist_build__pycross_tiktoken__tiktoken__0_13_0//:cargo_lock -- "$scratch/Cargo.lock"

lock="$scratch/Cargo.lock"
grep -q '^version = 4$' "$lock" || { echo "FAIL: not a Cargo.lock: $lock" >&2; exit 1; }
grep -q '^name = "tiktoken"$' "$lock" || { echo "FAIL: the root crate is missing from $lock" >&2; exit 1; }
grep -q 'source = "registry+https://github.com/rust-lang/crates.io-index"' "$lock" || { echo "FAIL: no crates.io dependency resolved in $lock" >&2; exit 1; }
echo "generated lock pins $(grep -c '^\[\[package\]\]' "$lock") packages"

# The generator locks the PATCHED sources: the case's pre_build_patch adds
# cfg-if to Cargo.toml, so a lock resolved from the pristine sdist would miss
# it and the offline build of the patched manifest could not use that lock.
grep -q '^name = "cfg-if"$' "$lock" || { echo "FAIL: the generated lock does not include the patched-in cfg-if dependency" >&2; exit 1; }
echo "generated lock carries the patched-in dependency: cfg-if"

# A lock regenerated in place must re-vendor: same file, same label, new
# contents. Bazel 9 stopped watching repository_ctx.path(label), and the
# configure tool reads the lock through its context JSON, so the watch in
# sdist_build is what makes the repository follow the file. autocfg is a real
# crates.io crate the lock does not pin (cfg-if is the patched-in dependency
# above), with its immutable checksum.
vendored_crates="@sdist_build__pycross_tiktoken__tiktoken__0_13_0//:vendored_crates"
external="$(bazel info output_base)/external"
vendor_dir="$(echo "$external"/*sdist_build__pycross_tiktoken__tiktoken__0_13_0/vendor)"

"$BAZEL" build "$vendored_crates"
[ ! -d "$vendor_dir/autocfg-1.4.0" ] || { echo "FAIL: autocfg vendored before the lock pins it" >&2; exit 1; }

cat >> "$lock_fixture" << 'EOF'

[[package]]
name = "autocfg"
version = "1.4.0"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "ace50bade8e6234aa140d9a2f552bbee1db4d353f69b8217bc503490fc1a9f26"
EOF

"$BAZEL" build "$vendored_crates"
[ -d "$vendor_dir/autocfg-1.4.0" ] || { echo "FAIL: the regenerated lock did not re-vendor" >&2; exit 1; }
echo "lock change at the same label re-vendored: autocfg-1.4.0"

cp "$scratch/Cargo.lock.fixture" "$lock_fixture"
"$BAZEL" build "$vendored_crates"
[ ! -d "$vendor_dir/autocfg-1.4.0" ] || { echo "FAIL: reverting the lock kept the stale vendored crate" >&2; exit 1; }
echo "reverting the lock dropped it again"
