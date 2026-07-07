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
        "wheels": """Depset of wheel record structs, one per wheel in the transitive closure. rules_py aggregates this field in
postorder. Producers must use `default` or `postorder`, the orders Bazel permits
in that aggregate. For collision classes that select one claimant, permissive
handling gives the later distinct element in the flattened sequence precedence.
Duplicate dependency edges do not create another precedence position. Fields:
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
  * `tl_claims`, `metadata_top_levels`, `cs_claims`: derived fields
    precomputed by `make_wheel_record` so venv assembly's collision
    resolution does per-wheel parsing once instead of per consuming binary.

Records must be built with `make_wheel_record` so the derived fields are
present and consistent with the raw ones.
""",
    },
)

def make_wheel_record(
        *,
        site_packages_rfpath,
        install_tree = None,
        top_levels = (),
        namespace_top_levels = (),
        namespace_entries = (),
        namespace_dirs = (),
        regular_roots = (),
        console_scripts = ()):
    """Build one PyWheelsInfo wheel record.

    Precomputes the collision-resolution claim structs that venv assembly
    consumes, so parsing happens once per wheel rather than per consuming
    binary. See the PyWheelsInfo field docs for the raw fields' semantics.

    Args:
        site_packages_rfpath: runfiles-root-relative path to the wheel's site-packages.
        install_tree: File holding the complete installed wheel tree.
        top_levels: immediate site-packages entry names; empty means unknown layout.
        namespace_top_levels: subset of top_levels that are PEP 420 namespaces.
        namespace_entries: concrete `/`-joined entries beneath the namespace top-levels.
        namespace_dirs: implicit-namespace directory skeleton under the top-levels.
        regular_roots: minimal `__init__.py`-carrying directories under the top-levels.
        console_scripts: entry points encoded as `"name=module:func"`.

    Returns:
        A struct for PyWheelsInfo.wheels.
    """
    ns_set = {tl: True for tl in namespace_top_levels}
    ns_entries_by_tl = {}
    for entry in namespace_entries:
        ns_entries_by_tl.setdefault(entry.split("/")[0], []).append(entry)

    tl_claims = []
    metadata_top_levels = []
    for tl in top_levels:
        if tl.endswith(".dist-info") or tl.endswith(".egg-info"):
            metadata_top_levels.append(tl)
            continue
        tl_claims.append((tl, struct(
            site_packages = site_packages_rfpath,
            is_ns = tl in ns_set,
            ns_entries = tuple(ns_entries_by_tl.get(tl, [])),
        )))

    cs_claims = []
    for entry in console_scripts:
        # Entry encoding: "name=module:func".
        if "=" not in entry:
            continue
        name, _, target = entry.partition("=")
        if ":" not in target:
            continue
        module, _, func = target.partition(":")
        name = name.strip()
        module = module.strip()
        func = func.strip()
        if not name or not module or not func:
            continue
        cs_claims.append((name, struct(
            site_packages = site_packages_rfpath,
            module = module,
            func = func,
        )))

    return struct(
        top_levels = tuple(top_levels),
        namespace_top_levels = tuple(namespace_top_levels),
        namespace_entries = tuple(namespace_entries),
        namespace_dirs = tuple(namespace_dirs),
        regular_roots = tuple(regular_roots),
        site_packages_rfpath = site_packages_rfpath,
        console_scripts = tuple(console_scripts),
        install_tree = install_tree,
        tl_claims = tuple(tl_claims),
        metadata_top_levels = tuple(metadata_top_levels),
        cs_claims = tuple(cs_claims),
    )

PyVirtualInfo = provider(
    doc = "FIXME",
    fields = {
        "dependencies": "Depset of required virtual dependencies, independent of their resolution status",
        "resolutions": "FIXME",
    },
)
