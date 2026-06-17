"""Providers to share information between targets in the graph."""

PyWheelsInfo = provider(
    doc = """Per-wheel metadata used to assemble a Python venv via symlinks at build time.

Each element of `wheels` describes one wheel in the transitive closure of a
target: the top-level names (packages / modules / *.dist-info directories)
it installs into `site-packages`, which of those are PEP 420 namespace
packages, the runfiles-root-relative path to the wheel's site-packages,
and the wheel's declared console-script entry points.

Downstream rules (notably `py_binary`) use this to create one
`ctx.actions.symlink` per top-level name, merging wheels into a single
`site-packages/` tree without invoking a runtime tool, and to generate
executable wrappers under `<venv>/bin/<name>` for console scripts.
""",
    fields = {
        "wheels": """Depset of wheel metadata structs, one per wheel in the transitive closure. Fields:
  * `top_levels`: tuple[str] — top-level names the wheel installs into site-packages.
  * `directory_top_levels`: tuple[str] — subset of top_levels installed as directories.
  * `namespace_top_levels`: tuple[str] — subset of top_levels that are PEP 420 namespace packages.
  * `namespace_entries`: tuple[str] — `/`-joined paths of the concrete entries beneath
    namespace top-levels, used to materialize a merged namespace directory from
    per-entry symlinks.
  * `namespace_dirs`: tuple[str] — implicit-namespace directory skeleton under the
    namespace top-levels.
  * `regular_roots`: tuple[str] — minimal directories under namespace top-levels
    carrying an `__init__.py`. Cross-referencing these with another wheel's
    `namespace_dirs` identifies regular packages that span wheels.
  * `site_packages_rfpath`: str — runfiles-root-relative path to the wheel's site-packages.
  * `console_scripts`: tuple[str] — entry points encoded as `"name=module:func"`.
  * `install_tree`: File — the complete installed wheel tree.
""",
    },
)

PyVenvLayoutInfo = provider(
    doc = "Private ownership metadata for files generated while assembling a venv.",
    fields = {
        "dependency_files": "depset[File] — generated dependency content that does not belong in a first-party source layer.",
        "wheel_aliases": "depset[File] — physical wheel-tree aliases that packaging rules must exclude without archiving.",
        "wheel_links": "depset[struct(link, install_tree, install_path)] — venv site-packages links and their paths within wheel install trees.",
    },
)

PyVirtualInfo = provider(
    doc = "FIXME",
    fields = {
        "dependencies": "Depset of required virtual dependencies, independent of their resolution status",
        "resolutions": "FIXME",
    },
)
