"""Providers to share information between targets in the graph."""

PyWheelsInfo = provider(
    doc = """Per-wheel metadata used to assemble a Python venv via symlinks at build time.

Each element of `wheels` describes one wheel in the transitive closure of a
target: its known `site-packages` layout, runfiles-root-relative package path,
and known console-script entry points.

Downstream rules (notably `py_binary`) use complete immediate layouts to link
top-level names, merge downloaded-wheel namespace metadata when available, and
generate executable wrappers under `<venv>/bin/<name>` for known scripts.
""",
    fields = {
        "wheels": """Depset of wheel metadata structs, one per wheel in the transitive closure. Fields:
  * `top_levels`: tuple[str] — every immediate entry the wheel installs into
    site-packages when `layout_known` is true, including files and directories.
  * `directory_top_levels`: tuple[str] — subset of top_levels installed as directories.
  * `layout_known`: bool — whether `top_levels` and `directory_top_levels`
    completely describe the installed wheel's immediate site-packages layout.
  * `namespace_top_levels`: tuple[str] — subset of top_levels classified as PEP
    420 namespace packages.
  * `namespace_entries`: tuple[str] — `/`-joined paths of concrete entries
    beneath namespace top-levels.
  * `namespace_dirs`: tuple[str] — producer-classified implicit-namespace
    directory skeleton under namespace top-levels.
  * `regular_roots`: tuple[str] — producer-classified minimal regular-package
    roots beneath namespace top-levels. An initializer may be source, bytecode,
    stub, or an extension module.
  * `site_packages_rfpath`: str — runfiles-root-relative path to the wheel's site-packages.
  * `console_scripts`: tuple[str] — entry points encoded as `"name=module:func"`.
  * `scripts_known`: bool — whether `console_scripts` completely describes the
    installed wheel, including when it is empty.
  * `install_tree`: File — the complete installed wheel tree.
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
