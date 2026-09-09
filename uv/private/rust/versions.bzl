"""Pinned Rust releases for PEP 517 sdist builds.

Hashes come from the `.sha256` files published next to each archive at
https://static.rust-lang.org/dist/. Keys are `<component>-<triple>`.
"""

# Exec platforms a build can run on.
RUST_HOST_TRIPLES = [
    "aarch64-apple-darwin",
    "aarch64-unknown-linux-gnu",
    "x86_64-apple-darwin",
    "x86_64-unknown-linux-gnu",
]

# Wheel target platforms, as (os, cpu) -> the rust-std triples a build for
# that platform may need. Linux carries both libcs: the toolchain cannot see
# the platform_libc flag, so the helper picks the triple at build time.
RUST_TARGETS = {
    ("linux", "x86_64"): ["x86_64-unknown-linux-gnu", "x86_64-unknown-linux-musl"],
    ("linux", "aarch64"): ["aarch64-unknown-linux-gnu", "aarch64-unknown-linux-musl"],
    ("macos", "x86_64"): ["x86_64-apple-darwin"],
    ("macos", "aarch64"): ["aarch64-apple-darwin"],
}

RUST_VERSIONS = {
    "1.90.0": {
        "rustc-x86_64-unknown-linux-gnu": "48c2a42de9e92fcae8c24568f5fe40d5734696a6f80e83cc6d46eef1a78f13c9",
        "rustc-aarch64-unknown-linux-gnu": "4e1a9987a11d7d91f0d5afbf5333feb62f44172e4a31f33ce7246549003217f2",
        "rustc-x86_64-apple-darwin": "594687a61b671445ea9fff0e6b6c6eef81cba30b005d22710217b4da8d2d2ecc",
        "rustc-aarch64-apple-darwin": "89551c0ba1cc6d0312aebc4a6cafe4497223217ea8e87c81f6afbe127dfaeeb6",
        "cargo-x86_64-unknown-linux-gnu": "9853db03d68578a30972e2755c89c66aec035fec641cf8f3a7117c81eec2578d",
        "cargo-aarch64-unknown-linux-gnu": "bd8d1da6fe88ea7e29338f24277c22156267447adbfc47d690467ad32d02c2a7",
        "cargo-x86_64-apple-darwin": "b2fa21c8fed854775e379bb4617145abd047d1be729e8383148139ba1d05c88f",
        "cargo-aarch64-apple-darwin": "17a4410a27bf7dad4765f3809265c225f25f8b009da3d4b76cd0927acdae04b5",
        "rust-std-x86_64-unknown-linux-gnu": "663f4ab7945b392d5e5294dec1b050a66820a20e86f084ec37eeb0f2f7ff5569",
        "rust-std-aarch64-unknown-linux-gnu": "4952abb7d9d3ed7cea4f7ea44dcb23dc67631fae4ac44a5f059b90a4b5e9223f",
        "rust-std-x86_64-unknown-linux-musl": "38490d575786f4688e83b357baeb022d8dde0ace2cb8c1357e060c76644fc56a",
        "rust-std-aarch64-unknown-linux-musl": "a603e135d4eb67ababdd193268a69937fa4490bafde592f2c931d17c7567b228",
        "rust-std-x86_64-apple-darwin": "dd731e6f9f30cb9b2928b92b084d2f12a3abf06a481ecbd8c3553c3e6f742139",
        "rust-std-aarch64-apple-darwin": "c36777aec17d617f85f94b7cb87bdd4270eeca30ef38c6f686809d163c881609",
    },
}

LATEST_RUST_VERSION = RUST_VERSIONS.keys()[-1]

def rust_archive_url(component, version, triple):
    """Upstream URL of one Rust dist component archive."""
    return "https://static.rust-lang.org/dist/{}-{}-{}.tar.xz".format(component, version, triple)

def rust_archive_prefix(component, version, triple):
    """Path inside the archive holding the component's install tree (bin/, lib/)."""
    inner = component if component != "rust-std" else "rust-std-" + triple
    return "{}-{}-{}/{}".format(component, version, triple, inner)

def triple_constraints(triple):
    """Bazel platform constraints for a Rust target triple."""
    cpu, _, rest = triple.partition("-")
    os = "macos" if "apple-darwin" in rest else "linux"
    return ["@platforms//os:" + os, "@platforms//cpu:" + cpu]
