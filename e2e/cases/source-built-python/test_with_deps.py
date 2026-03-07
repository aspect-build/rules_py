"""Verify markupsafe was built from sdist with the debug source-built interpreter.

This test proves the wheel was built with OUR interpreter by checking for 'cp311d'
in the WHEEL metadata Tag field. PBS never ships debug builds, so a 'cp311d' tag
is impossible to produce without a source-built --with-pydebug interpreter.
"""

import os
import sys
import sysconfig
import zipfile


def test_debug_interpreter():
    """Confirm we're running on a debug build."""
    assert "d" in sys.abiflags, (
        f"Expected debug interpreter (abiflags='d'), got: {sys.abiflags!r}"
    )


def test_markupsafe_import():
    """Import markupsafe and verify the C extension works."""
    import markupsafe
    result = markupsafe.escape("<script>alert('xss')</script>")
    assert "&lt;script&gt;" in str(result), f"Expected escaped HTML, got: {result}"
    print(f"markupsafe {markupsafe.__version__} works: {result}")


def test_markupsafe_debug_abi_tag():
    """Check the installed markupsafe WHEEL metadata for 'cp311d' tag.

    When markupsafe is built from sdist with a --with-pydebug interpreter, the
    resulting wheel's Tag field contains 'cp311d'. This is impossible to produce
    from a pre-built wheel or PBS interpreter.
    """
    from importlib.metadata import files as pkg_files

    wheel_info = None
    for f in pkg_files("markupsafe"):
        if str(f).endswith("WHEEL"):
            wheel_info = f.read_text()
            break

    assert wheel_info is not None, "Could not find WHEEL metadata for markupsafe"
    print(f"WHEEL metadata:\n{wheel_info}")

    # The Tag field must contain cp311d (debug ABI)
    assert "cp311d" in wheel_info, (
        f"Expected 'cp311d' in WHEEL Tag (proving debug-build origin), "
        f"but got:\n{wheel_info}"
    )


def test_markupsafe_so_debug_tag():
    """Verify the .so file has the debug ABI tag in its filename."""
    import markupsafe
    pkg_dir = os.path.dirname(markupsafe.__file__)
    so_files = [f for f in os.listdir(pkg_dir) if f.endswith(".so")]
    assert so_files, f"No .so files found in {pkg_dir}"
    for so in so_files:
        assert "cpython-311d" in so, (
            f"Expected 'cpython-311d' in .so filename, got: {so}"
        )
    print(f"Debug .so files: {so_files}")


if __name__ == "__main__":
    test_debug_interpreter()
    test_markupsafe_import()
    test_markupsafe_debug_abi_tag()
    test_markupsafe_so_debug_tag()
    print("\nAll checks passed: markupsafe built from sdist with debug interpreter!")
