"""Verify that the Python interpreter was built from source."""

import sys
import sysconfig


def test_version():
    """Check we're running on CPython 3.11.9."""
    assert sys.version_info[:3] == (3, 11, 9), (
        f"Expected CPython 3.11.9, got {sys.version}"
    )


def test_source_built_prefix():
    """Check that the interpreter was built with a non-standard prefix.

    Source-built interpreters have sysconfig CONFIG_ARGS reflecting the
    configure invocation, and sys.prefix pointing to the build install tree
    rather than a standard system path like /usr or /usr/local.
    """
    config_args = sysconfig.get_config_var("CONFIG_ARGS") or ""
    # The configure_make rule uses --prefix during the build
    assert "--prefix" in config_args, (
        f"Expected --prefix in CONFIG_ARGS, got: {config_args}"
    )

    # The prefix should NOT be a standard system path
    prefix = sys.prefix
    assert prefix not in ("/usr", "/usr/local", "/opt/homebrew"), (
        f"Expected non-system prefix, got: {prefix}"
    )


def test_debug_build():
    """Verify this is a debug build (--with-pydebug).

    Debug builds set sys.abiflags = 'd' and SOABI contains 'cpython-311d'.
    PBS never ships debug builds, so this definitively proves source-built.
    """
    assert hasattr(sys, "abiflags"), "sys.abiflags not found"
    assert "d" in sys.abiflags, (
        f"Expected 'd' in abiflags (debug build), got: {sys.abiflags!r}"
    )
    soabi = sysconfig.get_config_var("SOABI") or ""
    assert "cpython-311d" in soabi, (
        f"Expected 'cpython-311d' in SOABI, got: {soabi!r}"
    )


if __name__ == "__main__":
    test_version()
    test_source_built_prefix()
    test_debug_build()
    print("All checks passed: running on source-built debug CPython 3.11.9")
