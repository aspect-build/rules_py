"""Regression test for #547: namespace packages spanning multiple wheels.

The jaraco.functools and jaraco.classes packages both contribute to the
`jaraco` implicit namespace package. Importing from both must succeed,
verifying that the venv correctly supports packages that share a
top-level namespace.

Also asserts the namespace is merged CONCRETELY into site-packages:
static tools (mypy, pyright) inspect `site-packages/` directly and never
execute `.pth` files, so a namespace that only resolves through the
`.pth` fallback is invisible to them — along with the subpackages'
`py.typed` markers.
"""

import os
import sys
import sysconfig


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


def test_concrete_namespace_entries_in_site_packages():
    """The merged namespace must exist concretely in site-packages.

    Mimics how mypy/pyright discover packages: plain directory traversal
    of site-packages, without importing and without executing `.pth`
    files. Both wheels' subpackages — and their `py.typed` markers —
    must be reachable that way, and `jaraco/` must NOT gain an
    `__init__.py` (that would demote it from a PEP 420 namespace).
    """
    site_packages = sysconfig.get_paths()["purelib"]
    assert os.path.isdir(site_packages), f"no site-packages at {site_packages}"

    jaraco_dir = os.path.join(site_packages, "jaraco")
    assert os.path.isdir(jaraco_dir), (
        f"site-packages has no concrete jaraco/ entry at {jaraco_dir}; "
        "static tools (mypy/pyright) cannot see the namespace package "
        f"(site-packages holds: {sorted(os.listdir(site_packages))})"
    )
    assert not os.path.exists(os.path.join(jaraco_dir, "__init__.py")), (
        "jaraco/ must stay a PEP 420 namespace: no __init__.py"
    )

    for subpkg in ("functools", "classes"):
        pkg_dir = os.path.join(jaraco_dir, subpkg)
        assert os.path.isfile(os.path.join(pkg_dir, "__init__.py")), (
            f"jaraco/{subpkg}/__init__.py not reachable via site-packages "
            f"(jaraco/ holds: {sorted(os.listdir(jaraco_dir))})"
        )
        assert os.path.isfile(os.path.join(pkg_dir, "py.typed")), (
            f"jaraco/{subpkg}/py.typed not reachable via site-packages; "
            "type checkers would treat the package as untyped"
        )


if __name__ == "__main__":
    test_namespace_imports()
    test_jaraco_is_namespace_package()
    test_concrete_namespace_entries_in_site_packages()
    print("PASS: namespace package resolution works correctly")
