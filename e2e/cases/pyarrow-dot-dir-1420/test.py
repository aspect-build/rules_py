"""Regression #1420: pyarrow 14.0.1 installs despite its `pyarrow./` entry.

The Linux wheels ship an empty zip directory entry named `pyarrow./`
(trailing dot). The install action must skip directory entries before
path validation — reaching this test at all means the wheel unpacked.
The runtime asserts confirm the package is usable and that the invalid
directory name was never materialized.
"""

import sys
from pathlib import Path


def test_pyarrow_works() -> None:
    import pyarrow

    assert pyarrow.__version__ == "14.0.1", pyarrow.__version__
    table = pyarrow.table({"n": [1, 2, 3]})
    assert table.num_rows == 3


def test_dot_dir_not_materialized() -> None:
    import pyarrow

    site_packages = Path(pyarrow.__file__).resolve().parent.parent
    assert not (site_packages / "pyarrow.").exists(), (
        "directory entry `pyarrow./` should never be extracted"
    )


if __name__ == "__main__":
    test_pyarrow_works()
    test_dot_dir_not_materialized()
    print("PASS: pyarrow 14.0.1 installed and imported")
    sys.exit(0)
