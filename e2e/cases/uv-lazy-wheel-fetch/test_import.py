"""Import the native charset-normalizer wheel selected for the host platform.

Reaching this import at all proves the host's `whl_dist` repo was fetched and
its RECORD-derived layout installed a working package, while the unreachable
win_amd64 sibling was never fetched. Exercising the compiled detector proves
the native extension (charset_normalizer/md*.so) came across intact.
"""

import charset_normalizer


def main() -> None:
    best = charset_normalizer.from_bytes(b"hello world").best()
    assert best is not None, "charset-normalizer failed to detect encoding"
    assert str(best) == "hello world", best


if __name__ == "__main__":
    main()
