"""Custom UV binary locations in the workspace.

These binaries are built from https://github.com/xangcastle/uv
(branch: xancastle/bazel-integration) which adds --mode=bazel-runfiles
support for hermetic sandbox venvs.

Version: 0.11.6 (based on uv 0.11.6 + bazel-runfiles patch)

Build commands used:
  # macOS ARM (native)
  cargo build --release --bin uv

  # macOS Intel
  cargo build --release --target x86_64-apple-darwin --bin uv

  # Linux ARM (glibc)
  cargo zigbuild --release --target aarch64-unknown-linux-gnu.2.17 --bin uv

  # Linux x86_64 (glibc) — requires AR override for zig ar bug
  AR_x86_64_unknown_linux_gnu=$(xcrun --find ar) \\
    cargo zigbuild --release --target x86_64-unknown-linux-gnu.2.17 --bin uv

  # Linux ARM (musl, static)
  AR_aarch64_unknown_linux_musl=$(xcrun --find ar) \\
    cargo zigbuild --release --target aarch64-unknown-linux-musl --bin uv

  # Linux x86_64 (musl, static)
  AR_x86_64_unknown_linux_musl=$(xcrun --find ar) \\
    cargo zigbuild --release --target x86_64-unknown-linux-musl --bin uv
"""

# Map of platform triple -> workspace-relative binary path
UV_BINARIES = {
    "aarch64-apple-darwin": "tools/uv/bin/aarch64-apple-darwin/uv",
    "x86_64-apple-darwin": "tools/uv/bin/x86_64-apple-darwin/uv",
    "aarch64-unknown-linux-gnu": "tools/uv/bin/aarch64-unknown-linux-gnu/uv",
    "x86_64-unknown-linux-gnu": "tools/uv/bin/x86_64-unknown-linux-gnu/uv",
    "aarch64-unknown-linux-musl": "tools/uv/bin/aarch64-unknown-linux-musl/uv",
    "x86_64-unknown-linux-musl": "tools/uv/bin/x86_64-unknown-linux-musl/uv",
}
