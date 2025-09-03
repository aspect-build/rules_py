# Rust with Bazel

This directory contains configuration and scripts for using Rust with bazel.

## Managing Dependencies

When adding new Rust dependencies via Cargo, you must run repin to make them available to Bazel:

```bash
# First, add dependency to your Cargo.toml
cargo add my_dependency

# Then repin dependencies for Bazel
CARGO_BAZEL_ISOLATED=1 CARGO_BAZEL_REPIN=1 bazel build //...
```

If you are adding a crate which is used in multiple `Cargo.toml` files strongly consider making the create a workspace dependency.

```
cargo add --workspace-root YOUR_CRATE
```
