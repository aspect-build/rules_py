"""ty release versions and checksums for the default type checker toolchain."""

# Upstream release checksums, from each release's `sha256.sum`.
TY_VERSIONS = {
    "0.0.84": {
        "aarch64-apple-darwin": "c65c09f27bcef726c0b043dcee8d0f1e578bd1936799e5bc447235cbc3e19d91",
        "aarch64-pc-windows-msvc": "5310f17fc594e29e525ccd0eaa27b719b2af2a88ec7be38092af7036eaab5235",
        "aarch64-unknown-linux-musl": "e0f1cbe08fad84a164dbac8945730a349d506836f185afdb927e16395136d091",
        "x86_64-apple-darwin": "3891e5509d306721cee4dd4e69b94535dbd96371af7ec3b734ee65f25b167ae4",
        "x86_64-pc-windows-msvc": "e4b3c7cd30ff8b4ee4c2a62621f293341ad3c89fb3e7c6e4d2686150a4dbcf08",
        "x86_64-unknown-linux-musl": "da32bd4cbfe124f1df974e78cc163037c5d4b12ceec532b7ed785b5b74a76cd1",
    },
}

DEFAULT_TY_VERSION = "0.0.84"
