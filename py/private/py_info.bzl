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
        "transitive_pyi_files": "depset[File] — postorder depset of files needed only for type checking: `.pyi` type stubs in the transitive closure, plus the sources and stubs of any `pyi_deps`.",
        "imports": "depset[str] — import roots to place on `sys.path` (rlocation-root-relative).",
        "pyi_imports": "depset[str] — import roots needed only for type checking, from `pyi_deps` in the transitive closure. Optional: providers built without it are read as empty.",
        "import_dirs": "depset[str] — execroot-relative directories holding the files under `imports`, for type checkers, which run in the execroot rather than in runfiles. Each target contributes the directories its own import roots occupy on the output roots where it has files. Optional: a provider built without it is read through `unmapped_imports`.",
        "pyi_import_dirs": "depset[str] — the same as `import_dirs`, for `pyi_imports`. Optional.",
        "unmapped_imports": "depset[str] — import roots in the closure whose execroot directories are unknown, because they came from a provider without `import_dirs` (e.g. `@rules_python`'s). Optional.",
        "virtual_dependencies": "depset[str] — names of required virtual dependencies, independent of their resolution status.",
        "virtual_resolutions": "depset[struct(virtual, target)] — virtual-dependency-name to concrete-target resolutions.",
    },
)

# The name load sites and the public API import; same provider object.
PyInfo = RulesPyInfo
