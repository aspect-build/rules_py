"""The `PyInfo` provider produced and consumed by rules_py targets.

`PyInfo` carries the two pieces of information rules_py needs to assemble a
target's dependency closure: the transitive set of first-party Python sources,
and the import roots to place on `sys.path`. Targets in a dependency graph
aggregate these fields from their deps to build the eventual venv or wheel.

Defined here in one module and re-exported from `//py:defs.bzl` as public API.
"""

PyInfo = provider(
    doc = "Python source and import-path information for a target's dependency closure.",
    fields = {
        "transitive_sources": "depset[File] — postorder depset of first-party `.py` sources in the transitive closure.",
        "imports": "depset[str] — import roots to place on `sys.path` (rlocation-root-relative).",
    },
)
