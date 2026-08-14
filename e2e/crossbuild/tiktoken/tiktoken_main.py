#!/usr/bin/env python3
import tiktoken


def main() -> None:
    # tiktoken's real encodings (cl100k_base, o200k_base, ...) download their
    # BPE vocab over the network on first use — not available in a sandboxed
    # cross build/QEMU-emulated container. Build a minimal encoding directly
    # instead: one rank per raw byte, no merges, so encode() must exercise
    # the real compiled Rust core (_tiktoken.CoreBPE) to reduce "hi" to its
    # two literal byte values with no other correct output possible.
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
