"""The `PyInfo` provider produced and consumed by rules_py targets.

`PyInfo` carries the information rules_py needs to assemble a target's dependency
closure: the transitive set of first-party Python sources, the import roots to
place on `sys.path`, and the virtual-dependency declarations and their
resolutions. Targets in a dependency graph aggregate these fields from their
deps to build the eventual venv or wheel.
"""

# First binding wins the exported name, so diagnostics say `RulesPyInfo`.
RulesPyInfo = provider(
    doc = "Python source, import-path, and virtual-dependency information for a target's dependency closure.",
    fields = {
        "transitive_sources": "depset[File] — postorder depset of first-party `.py` sources in the transitive closure.",
        "imports": "depset[str] — import roots to place on `sys.path` (rlocation-root-relative).",
        "virtual_dependencies": "depset[str] — names of required virtual dependencies, independent of their resolution status.",
        "virtual_resolutions": "depset[struct(virtual, target)] — virtual-dependency-name to concrete-target resolutions.",
    },
)

# The name load sites and the public API import; same provider object.
PyInfo = RulesPyInfo
