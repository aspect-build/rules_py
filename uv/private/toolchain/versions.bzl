# TODO: generate this
# Map of UV version -> platform triple -> SHA256 of the release archive.
# Hashes are taken from the `.sha256` files published alongside each archive at
# https://github.com/astral-sh/uv/releases/download/<version>/.

UV_VERSIONS = {
    # From https://github.com/astral-sh/uv/releases/tag/0.11.21
    "0.11.21": {
        "aarch64-apple-darwin": "1f921d491ba5ffeea774eb04d6681ecee379101341cbb1500394993b541bf3f4",
        "aarch64-unknown-linux-gnu": "88e800834007cc5efd4675f166eb2a51e7e3ad19876d85fa8805a6fb5c922397",
        "aarch64-unknown-linux-musl": "e71badaed2a2c3a404a0a00974b51c7ed5f5bc7be947916846005b739c68a5a2",
        "arm-unknown-linux-musleabihf": "7cd6637deebacfa0224e53afb4dd7da4f464ba0ecc128f6f543897c157e39a0f",
        "armv7-unknown-linux-gnueabihf": "929440f991ccd8097e01be1ec831f673ac7bbf508e94819b4270f2873f69e658",
        "armv7-unknown-linux-musleabihf": "20f4b653a17adb09cdfa7f911d46a1f254b918a2b49bef1266c735ab4c6fced0",
        "i686-unknown-linux-gnu": "07125219898b1c8e71bc612d91b190927c6b192a7bce5dd029b1c9070e9b7049",
        "i686-unknown-linux-musl": "865eff26cef62b7862854e176d57d9e0164daeec595723132a81aa3611238798",
        "powerpc64le-unknown-linux-gnu": "0e97021d831f9670c8261f9270ecf94b83f1a90ff5312389e37a77676deaec87",
        "riscv64gc-unknown-linux-gnu": "63013d7afe8fd552b273a7a5ca1f1425c0c82b12d73454d24237876bc26006e9",
        "riscv64gc-unknown-linux-musl": "b869fe80435715b2b414443af28de96ed5d7f8c6759e12ba141abca221ebc0cd",
        "s390x-unknown-linux-gnu": "743694a86a05eaf15d292c3d757388c4b2a11b4a7eb67f000077b4d6c467347e",
        "x86_64-apple-darwin": "f3c8e5708a84b920c18b691214d54d2b0da6b984789caae95d47c95120cb7765",
        "x86_64-unknown-linux-gnu": "8c88519b0ef0af9801fcdee419bbb12116bd9e6b18e162ae093c932d8b264050",
        "x86_64-unknown-linux-musl": "9dadff5b9e7b1d2d011e41852a1cbca713d9d5d88194f2eb6bd240fa4fb0a719"
    },

    # From https://github.com/astral-sh/uv/releases/tag/0.11.7
    "0.11.7": {
        "aarch64-apple-darwin": "66e37d91f839e12481d7b932a1eccbfe732560f42c1cfb89faddfa2454534ba8",
        "aarch64-unknown-linux-gnu": "f2ee1cde9aabb4c6e43bd3f341dadaf42189a54e001e521346dc31547310e284",
        "aarch64-unknown-linux-musl": "46647dc16cbb7d6700f762fdd7a67d220abe18570914732bc310adc91308d272",
        "arm-unknown-linux-musleabihf": "238974610607541ccdb3b8f4ad161d4f2a4b018d749dc9d358b0965d9a1ddd0f",
        "armv7-unknown-linux-gnueabihf": "7aa9ddc128f58c0e667227feb84e0aac3bb65301604c5f6f2ab0f442aaaafd99",
        "armv7-unknown-linux-musleabihf": "77a237761579125b822d604973a2d4afb62b10a8f066db4f793906deec66b017",
        "i686-unknown-linux-gnu": "9c77e5b5f2ad4151c6dc29db5511af549e205dbd6e836e544c80ebfadd7a07ec",
        "i686-unknown-linux-musl": "b067ce3e92d04425bc11b84dc350f97447d3e8dffafccb7ebebde54a56bfc619",
        "powerpc64le-unknown-linux-gnu": "6ac23c519d1b06297e1e8753c96911fadee5abab4ca35b8c17da30e3e927d8ac",
        "riscv64gc-unknown-linux-gnu": "2052356c7388d26dc4dfcf2d44e28b3f800785371f37c5f37d179181fe377659",
        "riscv64gc-unknown-linux-musl": "219a25e413efb62c8ef3efb3593f1f01d9a3c22d1facf3b9c0d80b7caf3a5e56",
        "s390x-unknown-linux-gnu": "760152aa9e769712d52b6c65a8d7b86ed3aac25a24892cf5998a522d84942f9e",
        "x86_64-apple-darwin": "0a4bc8fcde4974ea3560be21772aeecab600a6f43fa6e58169f9fa7b3b71d302",
        "x86_64-unknown-linux-gnu": "6681d691eb7f9c00ac6a3af54252f7ab29ae72f0c8f95bdc7f9d1401c23ea868",
        "x86_64-unknown-linux-musl": "64ddb5f1087649e3f75aa50d139aa4f36ddde728a5295a141e0fa9697bfb7b0f"
    }, 

    "0.10.12": {
        "aarch64-apple-darwin": "ae738b5661a900579ec621d3918c0ef17bdec0da2a8a6d8b161137cd15f25414",
        "aarch64-pc-windows-msvc": "e79881e2c4f98a0f3a37b8770bf224e8fee70f6dcf8fc17055d8291bb1b0b867",
        "aarch64-unknown-linux-musl": "55bd1c1c10ec8b95a8c184f5e18b566703c6ab105f0fc118aaa4d748aabf28e4",
        "x86_64-apple-darwin": "17443e293f2ae407bb2d8d34b875ebfe0ae01cf1296de5647e69e7b2e2b428f0",
        "x86_64-pc-windows-msvc": "4c1d55501869b3330d4aabf45ad6024ce2367e0f3af83344395702d272c22e88",
        "x86_64-unknown-linux-musl": "adccf40b5d1939a5e0093081ec2307ea24235adf7c2d96b122c561fa37711c46",
    },
    
    "0.11.6": {
        "aarch64-apple-darwin": "4b69a4e366ec38cd5f305707de95e12951181c448679a00dce2a78868dfc9f5b",
        "aarch64-pc-windows-msvc": "bee7b25a7a999f17291810242b47565c3ef2b9205651a0fd02a086f261a7e167",
        "aarch64-unknown-linux-musl": "d14ebd6f200047264152daaf97b8bd36c7885a5033e9e8bba8366cb0049c0d00",
        "x86_64-apple-darwin": "8e0ed5035eaa28c7c8cd2a46b5b9a05bfff1ef01dbdc090a010eb8fdf193a457",
        "x86_64-pc-windows-msvc": "99aa60edd017a256dbf378f372d1cff3292dbc6696e0ea01716d9158d773ab77",
        "x86_64-unknown-linux-musl": "aa342a53abe42364093506d7704214d2cdca30b916843e520bc67759a5d20132",
    },
}


