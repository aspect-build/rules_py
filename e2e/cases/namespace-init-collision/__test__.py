"""Regression test for namespace package __init__.py stub collisions.

Both backports.weakref and backports.shutil-get-terminal-size install a
backports/__init__.py that declares a pkgutil namespace package. The files are
not byte-identical, but they are semantically equivalent, so the venv must not
treat them as a collision.
"""


def test_namespace_imports():
    import backports.shutil_get_terminal_size  # noqa: F401
    import backports.weakref  # noqa: F401


if __name__ == "__main__":
    test_namespace_imports()
    print("PASS: namespace package stubs did not collide")
