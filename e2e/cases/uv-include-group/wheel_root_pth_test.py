"""Exercise a root `.pth` file from a wheel with unknown topology.

`py_unpacked_wheel` without `top_levels` keeps its complete site-packages
directory under the venv's `_wheels` aliases.

The setuptools wheel ships `distutils-precedence.pth` at its
site-packages root. Body:
    import os; var = 'SETUPTOOLS_USE_DISTUTILS'; enabled = ...;
    enabled and __import__('_distutils_hack').add_shim();

Python's site.py only processes a `.pth` file if the directory it lives
in is registered as a *site directory* (i.e. added via
`site.addsitedir`). A plain `sys.path.append(...)` of the same
directory adds it to sys.path but skips the .pth scan.

The venv's pyvenv.cfg has `include-system-site-packages = false`, so
the interpreter's own bundled copy of `distutils-precedence.pth` does
not fire to mask the regression. We probe before any user-level import
disturbs the state — `_distutils_hack` ending up in `sys.modules` is
the side-effect of the .pth having executed at site-init.
"""

import sys


def main():
    leaked = sorted(
        m for m in sys.modules if "distutils" in m or "setuptools" in m
    )
    print(f"distutils/setuptools modules at startup: {leaked or '<none>'}")

    if "_distutils_hack" not in sys.modules:
        print(
            "FAIL: wheel-root distutils-precedence.pth did not execute "
            "at site-init. The wheel's site-packages was added to "
            "sys.path with a plain path line (no .pth scan) instead of "
            "via site.addsitedir."
        )
        sys.exit(1)

    print("PASS: wheel-root .pth fired — _distutils_hack present at startup.")


if __name__ == "__main__":
    main()
