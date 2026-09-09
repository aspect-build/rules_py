import sys

import support


def test_runs_requested_version() -> None:
    assert sys.version_info[:2] == (3, 12)
    assert support.__file__.endswith(".pyc"), support.__file__
