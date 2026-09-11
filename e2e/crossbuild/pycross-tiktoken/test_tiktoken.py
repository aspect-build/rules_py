#!/usr/bin/env python3
"""Round-trip encode/decode through tiktoken built from its sdist.

Ported from the spike workspace's //tiktoken:tiktoken_main.py. tiktoken's real
encodings download their BPE vocab over the network on first use, which is not
available in a sandboxed cross build. We build a minimal byte-level encoding so
encode() must exercise the compiled Rust core (_tiktoken.CoreBPE).
"""

import tiktoken


def main() -> None:
    mergeable_ranks = {bytes([i]): i for i in range(256)}
    enc = tiktoken.Encoding(
        name="byte-level-test",
        pat_str=r".+",
        mergeable_ranks=mergeable_ranks,
        special_tokens={},
    )
    tokens = enc.encode("hi")
    assert tokens == [104, 105], "expected [104, 105], got {}".format(tokens)
    decoded = enc.decode(tokens)
    assert decoded == "hi", "expected 'hi', got {!r}".format(decoded)
    print("OK")


if __name__ == "__main__":
    main()
