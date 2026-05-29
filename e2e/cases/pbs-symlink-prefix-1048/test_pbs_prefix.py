"""Regression test for issue #1048: PBS symlink chain breaks sys.base_prefix.

Python 3.11/3.12 reimplemented prefix discovery in pure Python (getpath.py).
Its resolvedpath() has a bug with multi-hop relative symlinks that traverse
.. components across repo boundaries — the exact shape of the venv's
bin/python → ../../../../interpreter_repo/bin/python3.11 chain.

When resolution fails, Python falls back to the compiled-in /install prefix
(absent at runtime), causing:
    ModuleNotFoundError: No module named 'encodings'

The fix: pyvenv.cfg's home= key now points directly to the PBS bin/ directory,
so Python only resolves the local python → python3.11 symlink (one hop).
"""

import os
import sys

from verify_venv import verify_all, verify_base_prefix, verify_in_venv


def test_base_prefix_not_install():
    assert sys.base_prefix != "/install", (
        f"sys.base_prefix is '/install' (the PBS compile-time prefix). "
        f"Python {sys.version_info.major}.{sys.version_info.minor} failed to "
        f"resolve the pyvenv.cfg home= symlink chain."
    )


def test_base_prefix_has_stdlib():
    stdlib = os.path.join(
        sys.base_prefix,
        "lib",
        f"python{sys.version_info.major}.{sys.version_info.minor}",
    )
    assert os.path.isdir(stdlib), (
        f"stdlib missing: {stdlib!r} (sys.base_prefix={sys.base_prefix!r})"
    )


if __name__ == "__main__":
    verify_all()
    test_base_prefix_not_install()
    test_base_prefix_has_stdlib()
    print(
        f"OK: sys.base_prefix={sys.base_prefix!r}, "
        f"Python {sys.version_info.major}.{sys.version_info.minor}"
    )
