"""Regression: augmax wheel with write-only RECORD must be importable.

augmax-0.4.1 ships dist-info/RECORD with Unix mode 0o100230 (-w--wx---).
Bazel's Java ZipInputStream preserves this on extraction; rctx.read() then
fails with "Permission denied". Without the metadata.bzl fix this test cannot
even build — the whl_dist repository rule aborts during bazel fetch.
Issue #1376.
"""

import augmax


def test_import() -> None:
    assert hasattr(augmax, "Chain"), (
        "augmax.Chain not found — import is incomplete"
    )


if __name__ == "__main__":
    test_import()
    print("OK: augmax with write-only RECORD imports correctly")
