"""Providers to share information between targets in the graph."""

PyWheelsInfo = provider(
    doc = """Installed wheel records used by venv assembly and image layering.

Each element of `wheels` describes one wheel in the transitive closure of a
target. Every record carries the complete installed tree. Repository-inspected
wheels also carry their site-packages layout and console scripts; source-built
wheels may leave that analysis-time metadata empty.

Venv rules project known layouts and generate console-script wrappers. Image
rules use `install_tree` to retain each wheel as a package leaf independently
of whether its metadata was available during analysis.
""",
    fields = {
        "wheels": """Depset of wheel record structs, one per wheel in the transitive
closure. rules_py aggregates this field in postorder. Producers must use
`default` or `postorder`, the orders Bazel permits in that aggregate. For
collision classes that select one claimant, permissive handling gives the later
distinct element in the flattened sequence precedence. Duplicate dependency
edges do not create another precedence position. Fields:
  * `top_levels`: tuple[str] — complete set of immediate `site-packages`
    entry names when nonempty; an empty tuple means the layout is unknown.
  * `namespace_top_levels`: tuple[str] — subset of top_levels that are PEP 420 namespace packages.
  * `namespace_entries`: tuple[str] — `/`-joined paths of the concrete entries beneath
    the namespace top-levels (e.g. `jaraco/functools`), used to materialise a merged
    namespace directory out of per-entry symlinks. May be absent on structs from
    older producers; consumers use `getattr` with a `()` default.
  * `namespace_dirs`: tuple[str] — implicit-namespace directory skeleton under the
    namespace top-levels (site-packages-relative `/`-joined paths). May be absent
    on structs from older producers; consumers use `getattr` with a `()` default.
  * `regular_roots`: tuple[str] — minimal directories under the namespace
    top-levels carrying an `__init__.py`. Cross-referencing a wheel's
    `regular_roots` with another wheel's `namespace_dirs` detects regular
    packages spanning wheels, which venv assembly must physically merge.
    May be absent on structs from older producers.
  * `site_packages_rfpath`: str — runfiles-root-relative path to the wheel's site-packages.
  * `console_scripts`: tuple[str] — entry points encoded as `"name=module:func"`.
  * `install_tree`: File — complete installed wheel tree.
""",
    },
)

PyVirtualInfo = provider(
    doc = "FIXME",
    fields = {
        "dependencies": "Depset of required virtual dependencies, independent of their resolution status",
        "resolutions": "FIXME",
    },
)
