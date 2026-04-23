"""Providers to share information between targets in the graph."""

PyWheelInfo = provider(
    doc = "Provides information about a Python Wheel",
    fields = {
        "files": "Depset of all files including deps for this wheel",
        "default_runfiles": "Runfiles of all files including deps for this wheel",
    },
)

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

Distinct from `PyWheelInfo` — that provider carries raw wheel archive
files for transitive collection (see `whl_requirements`); this one
carries the metadata needed to shape site-packages at analysis time.
""",
    fields = {
        "wheels": """Depset of `struct(top_levels, namespace_top_levels, site_packages_rfpath, console_scripts)`
— one per wheel in the transitive closure. Fields:
  * `top_levels`: tuple[str] — top-level names the wheel installs into site-packages.
  * `namespace_top_levels`: tuple[str] — subset of top_levels that are PEP 420 namespace packages.
  * `site_packages_rfpath`: str — runfiles-root-relative path to the wheel's site-packages.
  * `console_scripts`: tuple[str] — entry points encoded as `"name=module:func"`.
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
