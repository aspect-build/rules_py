"""Regression test for pkgutil namespace stub collisions.

backports.weakref and backports.shutil-get-terminal-size both install a
`backports/__init__.py` declaring a pkgutil namespace. The files are not
byte-identical but are equivalent, so the venv must merge the namespace
instead of reporting a collision.
"""

import os
import sys


def test_namespace_imports():
    import backports
    import backports.shutil_get_terminal_size
    import backports.weakref

    # One projected stub, every contributor merged beneath it: the namespace
    # resolves inside the venv alone, with no `.pth` fallback dir to graft.
    assert len(backports.__path__) == 1, backports.__path__
    site_packages = os.path.dirname(os.path.dirname(backports.__file__))
    assert site_packages.startswith(sys.prefix), (site_packages, sys.prefix)
    for module in (backports.shutil_get_terminal_size, backports.weakref):
        assert module.__file__.startswith(site_packages), (module.__file__, site_packages)


if __name__ == "__main__":
    test_namespace_imports()
    print("PASS: namespace package stubs did not collide")
