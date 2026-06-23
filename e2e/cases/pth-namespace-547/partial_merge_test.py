"""Incomplete hand-written topology selects a complete namespace merge.

`jaraco.functools` arrives through a hand-written `py_unpacked_wheel` that only
declares complete top-level metadata but no trusted nested entries. Its install
tree lets venv assembly merge the complete `jaraco` top-level alongside
`jaraco.classes` and remove both wheel roots from `.pth`.
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
    assert len(jaraco.__path__) == 1, (
        f"expected one concrete jaraco portion, got {list(jaraco.__path__)}"
    )


def test_both_contributors_are_concrete_and_not_pth_backed():
    site_packages = sysconfig.get_paths()["purelib"]
    for package in ("classes", "functools"):
        package_dir = os.path.join(site_packages, "jaraco", package)
        assert os.path.isfile(os.path.join(package_dir, "__init__.py")), package_dir
        assert os.path.isfile(os.path.join(package_dir, "py.typed")), package_dir
    assert not os.path.exists(os.path.join(site_packages, "jaraco", "__init__.py"))

    pth = "\n".join(
        open(os.path.join(site_packages, name), encoding="utf-8").read()
        for name in os.listdir(site_packages)
        if name.endswith(".pth")
    )
    assert "jaraco_functools_no_entries" not in pth, pth
    assert "jaraco_classes" not in pth, pth


if __name__ == "__main__":
    test_both_contributors_import()
    test_both_contributors_are_concrete_and_not_pth_backed()
    print("PASS: known-layout namespace contributors merge concretely")
