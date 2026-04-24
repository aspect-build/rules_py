"""Regression test for py_pytest_main(chdir = "...").

The test target below is configured with chdir = "examples/pytest/fixtures",
so the interpreter's working directory at test-start time should be that
directory — opening "hello.json" as a relative path should resolve to
the committed fixture, with no need for a runfiles-based absolute path.

If the chdir substitution in py_pytest_main.bzl's template expansion
ever regresses (or the replacement-token marker drifts from
`_ = 0  # no-op`), this test will fail to find hello.json.
"""

import json
import os


def test_cwd_is_fixtures_dir():
    cwd = os.getcwd()
    assert cwd.endswith("/examples/pytest/fixtures"), (
        f"expected chdir into examples/pytest/fixtures, got {cwd!r}"
    )


def test_relative_open_resolves_against_chdir():
    # No path prefix — if chdir didn't happen, this open() would raise.
    with open("hello.json") as f:
        data = json.load(f)
    assert data["message"] == "Hello, world."
