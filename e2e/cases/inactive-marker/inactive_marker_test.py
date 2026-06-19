"""Inactive marker-only deps resolve to an empty package, not an error.

Every dependency below is gated behind a marker that is false under the test
toolchain (non-Windows host, CPython 3.11), so each resolves to the empty SCC
fallback. Depending on them must build (the selects are total) yet contribute
nothing importable. tqdm is the exception: it is active and imports fine, but
its sole dependency (colorama) is Windows-gated, so the transitive edge falls
back to empty and colorama stays absent.
"""

import importlib


def _assert_absent(module):
    try:
        importlib.import_module(module)
    except ImportError:
        return
    raise AssertionError(
        "{} imported on a non-Windows host; an inactive marker-only dependency "
        "should resolve to the empty package and contribute nothing".format(module)
    )


def _assert_present(module):
    importlib.import_module(module)


def main():
    # 1. Simple marker (sys_platform == 'win32').
    _assert_absent("iniconfig")
    # 2. Compound marker (python_version >= '3.12' and sys_platform == 'win32').
    _assert_absent("six")
    # 3. tqdm is active; its transitive Windows-only colorama edge is not.
    _assert_present("tqdm")
    _assert_absent("colorama")


if __name__ == "__main__":
    main()
