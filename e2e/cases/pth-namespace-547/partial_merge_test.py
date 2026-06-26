"""Gap-1 regression: a namespace with a mix of entried and entryless wheels.

`jaraco.classes` arrives via a uv `whl_install` (carries `namespace_entries`,
so it merges concretely into site-packages). `jaraco.functools` arrives via a
hand-written `py_unpacked_wheel` that deliberately omits `namespace_entries`
(simulating metadata we can't synthesise). Both claim the `jaraco` PEP 420
namespace.

The entryless contributor must NOT poison the well-formed one: `jaraco.classes`
has to stay concretely visible in site-packages (the mypy/pyright view), while
`jaraco.functools` still resolves at import time through the `.pth` fallback.
A concrete namespace portion and a `.pth`/addsitedir portion merge into one
`jaraco.__path__` at runtime.
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
    # Both contributions are present in the merged __path__.
    assert len(jaraco.__path__) >= 2, (
        f"expected jaraco.__path__ to merge >=2 portions, got {list(jaraco.__path__)}"
    )


def test_entried_contributor_is_concrete():
    """The uv (entried) wheel's subpackage must be reachable by plain
    directory traversal of site-packages — the way mypy/pyright see it —
    even though it shares the namespace with an entryless wheel."""
    site_packages = sysconfig.get_paths()["purelib"]
    classes_init = os.path.join(site_packages, "jaraco", "classes", "__init__.py")
    assert os.path.isfile(classes_init), (
        f"jaraco/classes/__init__.py not concrete at {classes_init}; the "
        "entryless functools contributor poisoned the well-formed classes "
        "wheel (gap-1 regression)"
    )
    assert os.path.isfile(
        os.path.join(site_packages, "jaraco", "classes", "py.typed")
    ), "jaraco/classes/py.typed not reachable via site-packages"
    # jaraco/ itself must stay init-less so PEP 420 merges the .pth portion.
    assert not os.path.exists(os.path.join(site_packages, "jaraco", "__init__.py"))


if __name__ == "__main__":
    test_both_contributors_import()
    test_entried_contributor_is_concrete()
    print("PASS: entried contributor stays concrete; entryless merges via .pth")
