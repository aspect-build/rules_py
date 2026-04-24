# TODO: generate this
# Map of UV version -> platform triple -> SHA256 of the release archive.
# Hashes are taken from the `.sha256` files published alongside each archive at
# https://github.com/astral-sh/uv/releases/download/<version>/.

UV_VERSIONS = {
    "0.10.12": {
        "aarch64-apple-darwin": "ae738b5661a900579ec621d3918c0ef17bdec0da2a8a6d8b161137cd15f25414",
        "aarch64-pc-windows-msvc": "e79881e2c4f98a0f3a37b8770bf224e8fee70f6dcf8fc17055d8291bb1b0b867",
        "aarch64-unknown-linux-gnu": "0ed7d20f49f6b9b60d45fdfcac28f3ac01a671a6ef08672401ed2833423fea2a",
        "aarch64-unknown-linux-musl": "55bd1c1c10ec8b95a8c184f5e18b566703c6ab105f0fc118aaa4d748aabf28e4",
        "x86_64-apple-darwin": "17443e293f2ae407bb2d8d34b875ebfe0ae01cf1296de5647e69e7b2e2b428f0",
        "x86_64-pc-windows-msvc": "4c1d55501869b3330d4aabf45ad6024ce2367e0f3af83344395702d272c22e88",
        "x86_64-unknown-linux-gnu": "ec72570c9d1f33021aa80b176d7baba390de2cfeb1abcbefca346d563bf17484",
        "x86_64-unknown-linux-musl": "adccf40b5d1939a5e0093081ec2307ea24235adf7c2d96b122c561fa37711c46",
    },
    "0.11.6": {
        "aarch64-apple-darwin": "4b69a4e366ec38cd5f305707de95e12951181c448679a00dce2a78868dfc9f5b",
        "aarch64-pc-windows-msvc": "bee7b25a7a999f17291810242b47565c3ef2b9205651a0fd02a086f261a7e167",
        "aarch64-unknown-linux-gnu": "d5be4bf7015ea000378cb3c3aba53ba81a8673458ace9c7fa25a0be005b74802",
        "aarch64-unknown-linux-musl": "d14ebd6f200047264152daaf97b8bd36c7885a5033e9e8bba8366cb0049c0d00",
        "x86_64-apple-darwin": "8e0ed5035eaa28c7c8cd2a46b5b9a05bfff1ef01dbdc090a010eb8fdf193a457",
        "x86_64-pc-windows-msvc": "99aa60edd017a256dbf378f372d1cff3292dbc6696e0ea01716d9158d773ab77",
        "x86_64-unknown-linux-gnu": "0c6bab77a67a445dc849ed5e8ee8d3cb333b6e2eba863643ce1e228075f27943",
        "x86_64-unknown-linux-musl": "aa342a53abe42364093506d7704214d2cdca30b916843e520bc67759a5d20132",
    },
}
