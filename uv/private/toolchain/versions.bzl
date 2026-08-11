# TODO: generate this
# Map of UV version -> platform triple -> SHA256 of the release archive.
# Hashes are taken from the `.sha256` files published alongside each archive at
# https://github.com/astral-sh/uv/releases/download/<version>/.

UV_VERSIONS = {
    "0.10.12": {
        "aarch64-apple-darwin": "ae738b5661a900579ec621d3918c0ef17bdec0da2a8a6d8b161137cd15f25414",
        "aarch64-pc-windows-msvc": "e79881e2c4f98a0f3a37b8770bf224e8fee70f6dcf8fc17055d8291bb1b0b867",
        "aarch64-unknown-linux-musl": "55bd1c1c10ec8b95a8c184f5e18b566703c6ab105f0fc118aaa4d748aabf28e4",
        "x86_64-apple-darwin": "17443e293f2ae407bb2d8d34b875ebfe0ae01cf1296de5647e69e7b2e2b428f0",
        "x86_64-pc-windows-msvc": "4c1d55501869b3330d4aabf45ad6024ce2367e0f3af83344395702d272c22e88",
        "x86_64-unknown-linux-musl": "adccf40b5d1939a5e0093081ec2307ea24235adf7c2d96b122c561fa37711c46",
    },
    "0.11.21": {
        "aarch64-apple-darwin": "1f921d491ba5ffeea774eb04d6681ecee379101341cbb1500394993b541bf3f4",
        "aarch64-pc-windows-msvc": "74e443f8004022dde57a1bd0d10c097830f9ea8feb4ec927db52cd5d805c2f48",
        "aarch64-unknown-linux-musl": "e71badaed2a2c3a404a0a00974b51c7ed5f5bc7be947916846005b739c68a5a2",
        "x86_64-apple-darwin": "f3c8e5708a84b920c18b691214d54d2b0da6b984789caae95d47c95120cb7765",
        "x86_64-pc-windows-msvc": "ace861f360c6de2babedc1607d0f454b6b09a820dbc8182dc15af927e4df9589",
        "x86_64-unknown-linux-musl": "9dadff5b9e7b1d2d011e41852a1cbca713d9d5d88194f2eb6bd240fa4fb0a719",
    },
}
