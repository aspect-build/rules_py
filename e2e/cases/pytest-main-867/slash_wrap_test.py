"""Regression for #483/#723 on the baked-args codegen path: a slash-containing
target name must still dunder-wrap the generated main's *basename* (preserving
the directory prefix) so pytest never collects it.

This test runs under a slash-named py_pytest_test with pytest_args set, so its
own generated entrypoint is the artifact under test.
"""

import glob
import os


def test_generated_main_basename_is_dunder_wrapped() -> None:
    mains = glob.glob("pytest-main-867/**/*pytest_main*.py", recursive=True)
    assert mains, "generated pytest main not found in runfiles"
    for path in mains:
        base = os.path.basename(path)
        assert base.startswith("__test__"), (
            "generated main %r is not dunder-wrapped; pytest would collect it" % path
        )
