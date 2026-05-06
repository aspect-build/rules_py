"""Smoke test that pytest is importable.

Each py_test in BUILD.bazel resolves pytest via a different label shape
(qualified `@pypi_shared_848//project/proj_a_848:pytest`, qualified `.proj_b_848:pytest`,
or unqualified `@pypi_shared_848//pytest` under a uniquely-named dep_group).
The test body itself just verifies the resolution actually delivered a working
pytest install — the interesting assertion is the BUILD-graph wiring.
"""

import pytest


def test_pytest_resolved():
    # If pytest's __version__ is readable, the wheel was successfully resolved
    # and unpacked into the venv via whichever label path BUILD.bazel chose.
    assert pytest.__version__
