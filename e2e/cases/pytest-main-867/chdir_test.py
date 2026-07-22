"""Regression: py_pytest_test(chdir=...) must not defeat rooted discovery.

The .pytest_paths discovery-root file is resolved before the baked chdir. Before
the fix, chdir ran first and the paths file was then looked up relative to the
post-chdir CWD, wasn't found, and pytest fell back to autodiscovering from the
chdir directory (chdir_data, which holds no tests) — collecting nothing.
"""

import os


def test_chdir_applied() -> None:
    # The baked chdir moved CWD into chdir_data before pytest started. This
    # source being collected at all (from the package root, despite the chdir)
    # is itself the discovery-survived-chdir regression — under the bug pytest
    # exited 5 with no tests.
    assert os.path.basename(os.getcwd()) == "chdir_data"
