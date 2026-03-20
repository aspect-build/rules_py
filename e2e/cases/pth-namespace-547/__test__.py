"""Regression test for #547: namespace packages spanning multiple wheels.

The jaraco.functools and jaraco.classes packages both contribute to the
`jaraco` implicit namespace package. Importing from both must succeed,
verifying that the venv correctly supports packages that share a
top-level namespace.
"""

import os
import sys


def test_namespace_imports():
    """Both jaraco sub-packages must be importable."""
    import jaraco.functools
    import jaraco.classes

    # Verify both packages loaded real modules (not empty stubs)
    assert jaraco.functools.__file__ is not None, (
        "jaraco.functools should be a real module with __file__"
    )
    assert jaraco.classes.__file__ is not None, (
        "jaraco.classes should be a real module with __file__"
    )


def test_jaraco_is_namespace_package():
    """The jaraco package must be a namespace package, not a regular one."""
    import jaraco

    # Namespace packages have no __file__ attribute (or it's None).
    # In a symlink-forest venv, both packages are merged into one
    # site-packages directory, so __path__ may have only one entry —
    # but jaraco must still be a namespace package (no __file__).
    assert not hasattr(jaraco, "__file__") or jaraco.__file__ is None, (
        f"jaraco should be a namespace package but has __file__={jaraco.__file__}"
    )


if __name__ == "__main__":
    test_namespace_imports()
    test_jaraco_is_namespace_package()
    print("PASS: namespace package resolution works correctly")
