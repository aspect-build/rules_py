"""Regression: module naming must not truncate at a namespace package (#479, #368).

`namespace_pkg/` deliberately has no `__init__.py`, which is the shape of an
ordinary Bazel package. pytest's default module naming walks up only through
directories that have one, so it stops at `namespace_pkg/` and imports this file
as `sub.module_name_test` -- binding `sys.modules["sub"]` to this package. When
such a package shares a name with an installed distribution, the distribution is
shadowed for the code under test, and `import <dist>` silently resolves to
first-party code.

The enclosing case directory is hyphenated, so it cannot form part of a dotted
module name; that bounds the expected name to the portion under test.
"""

import sys


def test_name_includes_the_namespace_package() -> None:
    assert __name__.endswith("namespace_pkg.sub.module_name_test"), (
        f"module imported as {__name__!r}; naming truncated at the first "
        "directory without an __init__.py"
    )


def test_inner_package_is_not_bound_as_top_level() -> None:
    bound = sys.modules.get("sub")
    assert bound is None or bound.__name__ != "sub", (
        "the inner package was bound as top-level `sub`, which would shadow an "
        "installed distribution of that name"
    )
