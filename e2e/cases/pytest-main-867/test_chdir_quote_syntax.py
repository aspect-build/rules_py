"""Regression for the chdir renderer: a chdir path containing a quote must be
emitted as a valid Python string literal. The old `os.chdir('{}')` renderer
produced a SyntaxError for such paths; `repr()` renders them correctly.

`chdir_quote_main` (a py_pytest_main with a quoted chdir) is a dep, so its
generated entrypoint sits in runfiles. We compile it here rather than run it,
so the assertion is about the rendered syntax, not whether the directory exists.
"""

import glob


def test_generated_chdir_is_valid_python() -> None:
    mains = glob.glob("pytest-main-867/__test__chdir_quote_main__.py")
    assert mains, "generated chdir main not found in runfiles"
    src = open(mains[0], encoding="utf-8").read()
    assert "it's-data" in src, "the quoted chdir path did not land in the main"
    # Raises SyntaxError under the old single-quote renderer.
    compile(src, mains[0], "exec")
