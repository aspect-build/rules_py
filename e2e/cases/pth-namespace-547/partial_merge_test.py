"""A namespace split between generated and hand-written wheel metadata.

Both contributors must be merged into one concrete `jaraco` directory.
"""

import os
import sys
import sysconfig


def test_both_contributors_import():
    import jaraco.classes
    import jaraco.functools

    assert jaraco.classes.__file__ is not None
    assert jaraco.functools.__file__ is not None
    # jaraco must remain a namespace package, not be promoted to regular.
    import jaraco

    assert not hasattr(jaraco, "__file__") or jaraco.__file__ is None, (
        f"jaraco should stay a namespace package, got __file__={jaraco.__file__}"
    )
    assert len(jaraco.__path__) == 1, list(jaraco.__path__)


def test_both_contributors_are_concrete():
    site_packages = sysconfig.get_paths()["purelib"]
    for package in ("classes", "functools"):
        assert os.path.isfile(
            os.path.join(site_packages, "jaraco", package, "__init__.py")
        )
    assert not os.path.exists(os.path.join(site_packages, "jaraco", "__init__.py"))


if __name__ == "__main__":
    test_both_contributors_import()
    test_both_contributors_are_concrete()
    print("PASS: generated and hand-written wheel metadata merge concretely")
