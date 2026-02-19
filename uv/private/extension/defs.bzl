"""A Bazel module extension for resolving Python dependencies from a `uv.lock` file.

This extension provides a mechanism for resolving Python dependencies declared in a
`pyproject.toml` and locked in a `uv.lock` file. It generates a dependency graph,
handles platform-specific constraints, and creates repository rules for fetching
pre-built wheels (bdists) or building wheels from source (sdists).

The extension is designed to handle complex dependency scenarios, including:
- Cross-platform builds for different operating systems and architectures.
- Hermetic builds of source distributions.
- Dependency cycles, which are resolved by computing the strongly connected
  components (SCCs) of the dependency graph.

## Example

The following example shows how to use the `uv` module extension in a `MODULE.bazel`
file:

```starlark
uv = use_extension("@aspect_rules_py//uv:extension.bzl", "uv")
uv.hub(name = "uv")
uv.project(
    hub_name = "uv",
    name = "my_project",
    pyproject = "//:pyproject.toml",
    lock = "//:uv.lock",
)
use_repo(uv, "uv")
```

This configuration declares a `uv` hub and registers a project with its
`pyproject.toml` and `uv.lock` files. The `use_repo` directive then makes the
resolved dependencies available in the `@uv` repository.

## Common Types

- **Dependency:** A tuple of `(project_id, package_name, version, extra)` that
  uniquely identifies a package within a lockfile. `project_id` is a unique
  identifier for the lockfile, `package_name` is the normalized name of the
  package, `version` is the package version, and `extra` is the optional extra
  (or `__base__` for the base package).
- **Marker:** A string representing a PEP 508 marker, used to specify
  environment-specific dependencies (e.g.,
  `"sys_platform == 'linux'"`).
- **SCC:** A Strongly Connected Component, which is a set of packages that have
  cyclic dependencies on each other.

## Appendix

[1] https://peps.python.org/pep-0751/
[2] https://peps.python.org/pep-0751/#locking-build-requirements-for-sdists
"""

load("@bazel_features//:features.bzl", features = "bazel_features")
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")
load("//uv/private:normalize_name.bzl", "normalize_name")
load("//uv/private/constraints:repository.bzl", "configurations_hub")
load("//uv/private/git_archive:repository.bzl", "git_archive")
load("//uv/private/pprint:defs.bzl", "pprint")
load("//uv/private/sdist_build:repository.bzl", "sdist_build")
load("//uv/private/tomltool:toml.bzl", "toml")
load("//uv/private/uv_hub:repository.bzl", "uv_hub")
load("//uv/private/uv_project:repository.bzl", "uv_project")
load("//uv/private/whl_install:repository.bzl", "whl_install")
load(":graph_utils.bzl", "activate_extras", "collect_sccs")
load(":lockfile.bzl", "build_marker_graph", "collect_bdists", "collect_configurations", "collect_markers", "collect_sdists", "normalize_deps")
load(":projectfile.bzl", "collate_versions_by_name", "collect_activated_extras", "extract_requirement_marker_pairs")

def _parse_hubs(module_ctx):
    """Parses `uv.hub()` declarations from all modules.

    This function iterates through all the modules in the Bazel dependency graph
    and collects the `uv.hub()` declarations. It produces a dictionary of hub
    specifications that is used to validate project registrations.

    Args:
        module_ctx: The Bazel module context.

    Returns:
        A dictionary of hub specifications, where the keys are hub names and the
        values are dictionaries of module names that declared the hub.
    """

    # As with `rules_python` hub names have to be globally unique :/
    hub_specs = {}

    # Collect all hubs, ensure we have no dupes
    for mod in module_ctx.modules:
        for hub in mod.tags.declare_hub:
            hub_specs.setdefault(hub.hub_name, {})
            hub_specs[hub.hub_name][mod.name] = 1

    # Note that we ARE NOT validating that the same hub name is registered by
    # one and only one repository. This allows `@pypi` which we think should be
    # the one and only conventional hub to be referenced by many modules since
    # we disambiguate the build configuration on the "venv" not the hub.

    return hub_specs

def _parse_projects(module_ctx, hub_specs):
    """Parses all `uv.project()` declarations from all modules.

    This function is the core of the module extension's logic. It iterates
    through all the `uv.project()` declarations, parses the `pyproject.toml` and
    `uv.lock` files, and builds up the complete dependency graph.

    Args:
        module_ctx: The Bazel module context.
        hub_specs: A dictionary of hub specifications, as returned by
            `_parse_hubs`.

    Returns:
        A struct containing all the parsed information, including the dependency
        graph, SCCs, and configurations for all the repository rules that need
        to be generated.
    """

    hub_cfgs = {}
    project_cfgs = {}
    marker_specs = {}
    whl_configurations = {}

    sdist_specs = {}
    sdist_table = {}

    bdist_specs = {}
    bdist_table = {}

    sbuild_specs = {}

    install_cfgs = {}
    install_table = {}

    # FIXME: Collect build deps files/annotations

    # Collect all hubs, ensure we have no dupes
    for mod in module_ctx.modules:
        for project in mod.tags.project:
            project_data = toml.decode_file(module_ctx, project.pyproject)
            lock_data = toml.decode_file(module_ctx, project.lock)

            # This SHOULD be stable enough.
            # We'll rebuild the lock hub whenever the toml changes.
            # Reusing the name is fine.
            # project_stamp = sha1(str(project.pyproject))[:16]
            project_stamp = normalize_name(project_data["project"]["name"])
            project_id = "project__" + project_stamp

            # Read these from the project or honor the module state
            project_name = project.name or project_data["project"]["name"]

            # FIXME: Error if this wasn't provided and the version is marked as dynamic
            project_version = project.version or project_data["project"]["version"]

            if project.hub_name not in hub_specs:
                fail("Project {} in {} refers to hub {} which is not configured for that module. Please declare it.".format(project_name, mod.name, project.hub_name))

            default_versions, lock_data = normalize_deps(project_id, lock_data)

            def _resolve(package):
                name = normalize_name(package["name"])
                if "version" in package:
                    return (project_id, name, package["version"].replace(".", "_"), "__base__")
                elif name in default_versions:
                    return default_versions[name]
                else:
                    fail("Unable to identify id for package {} for lock {}\n{}".format(package, project.lock, pprint(default_versions)))

            lock_build_dep_anns = {}
            for ann in mod.tags.unstable_annotate_packages:
                if ann.lock == project.lock:
                    annotations = toml.decode_file(module_ctx, ann.src)
                    for package in annotations.get("package", []):
                        k = _resolve(package)
                        deps = []
                        for dep in package.get("build-dependencies", []):
                            deps.append(_resolve(dep))
                        lock_build_dep_anns[k] = deps

            overridden_packages = {}

            # FIXME: This inner join is correct and easy, but it doesn't allow us to warn if there are annotations that don't join.
            for override in mod.tags.override_package:
                if override.lock == project.lock:
                    v = override.version or default_versions.get(normalize_name(override.name))[2]
                    if not v:
                        fail("Overridden project {} neither specifies a version nor has an implied singular version in the lockfile!".format(override.name, project.lock))
                    k = (project_id, normalize_name(override.name), v, "__base__")
                    print("Overriding {}@{} in {} with {}".format(override.name, v, project_name, override.target))
                    install_table[k] = str(override.target)

            # Lazily evaluated cache
            lock_build_deps = None

            marker_graph = build_marker_graph(project_id, lock_data)

            marker_specs.update(collect_markers(marker_graph))

            bd, bt = collect_bdists(lock_data)
            bdist_specs.update(bd)
            bdist_table.update(bt)

            sd, st = collect_sdists(project_stamp, lock_data)
            sdist_specs.update(sd)
            sdist_table.update(st)

            whl_configurations.update(collect_configurations(lock_data))

            configuration_names, activated_extras = collect_activated_extras(project.lock, project_data, default_versions, marker_graph)
            version_activations = collate_versions_by_name(activated_extras)

            # Mapping from SCC ID to marked SCC members
            scc_graph = {}

            # Mapping from SCC ID to marked SCC dependencies
            scc_deps = {}

            # Mapping from package to cfg to the SCC for that package in that cfg
            package_cfg_sccs = {}
            for cfg in configuration_names:
                cfgd_marker_graph = activate_extras(marker_graph, activated_extras, cfg)
                cfgd_dep_to_scc, cfgd_scc_graph, cfgd_scc_deps = collect_sccs(cfgd_marker_graph)

                # Aggregate the dependency graphs Note that this may be overly
                # simplistic, since markers COULD vary per configured graph;
                # ignoring that for now.
                scc_graph.update(cfgd_scc_graph)
                scc_deps.update(cfgd_scc_deps)

                # This one's slightly tricky
                for package, scc in cfgd_dep_to_scc.items():
                    package_cfg_sccs.setdefault(package, {})[cfg] = scc

            marked_package_cfg_sccs = {}
            for package, cfgs in version_activations.items():
                for cfg, versions in cfgs.items():
                    for version, markers in versions.items():
                        # Map the version to a scc in this configuration, while collecting version conditional markers
                        marked_package_cfg_sccs.setdefault(package, {}).setdefault(cfg, {}).setdefault(package_cfg_sccs[version][cfg], {}).update(markers)

            # Translate the package lock into installs for this project
            for package in lock_data.get("package", []):
                install_key = (project_id, package["name"], package["version"], "__base__")
                if install_key in install_table:
                    # Case of an overridden package
                    continue

                if install_key in install_table:
                    continue
                elif "editable" in package["source"] or "virtual" in package["source"]:
                    if package["name"] == project_name:
                        continue
                    else:
                        fail("Virtual package {} in lockfile {} doesn't have a mandatory `uv.override_package()` annotation!".format(package["name"], project.lock))

                k = "whl_install__{}__{}__{}".format(project_stamp, package["name"], package["version"].replace(".", "_"))
                install_table[install_key] = "@{}//:install".format(k)
                sbuild_id = "sdist_build__{}__{}__{}".format(project_stamp, package["name"], package["version"].replace(".", "_"))
                sdist = sdist_table.get(sbuild_id)

                # WARNING: Loop invariant; this flag needs to be False by
                # default and set if we do a build.
                has_sbuild = False

                # HACK: If there's a -none-any wheel for the package, then
                # we can actually skip creating the sdist build because
                # we'll never use it. This allows projects which can do
                # anyarch builds from bdists to avoid providing build deps.
                #
                # FIXME: This condition is actually incomplete, `py2.py3` wheels
                # match the same condition.
                #
                # FIXME: If we add support for a sdist-only mode then this is
                # just wrong.
                has_none_any = any(["-none-any.whl" in it["url"] for it in package.get("wheels", [])])
                if sdist and not (has_none_any and project.elide_sbuilds_with_anyarch):
                    # HACK: Note that we resolve these LAZILY so that
                    # bdist-only or fully overridden configurations don't
                    # have to provide the build tools.

                    # FIXME: We can read the [build-system] requires=
                    # property if it exists for the sdist. Question is how
                    # to defer choosing deps until the repo rule when we
                    # could do pyproject.toml introspection.
                    build_deps = lock_build_dep_anns.get(install_key)
                    if build_deps == None:
                        if lock_build_deps == None:
                            lock_build_deps = [
                                it[0]
                                for req in project.default_build_dependencies
                                for it in extract_requirement_marker_pairs(project.lock, req, default_versions)
                            ]

                        build_deps = lock_build_deps

                    sbuild_specs[sbuild_id] = struct(
                        src = sdist,
                        deps = ["@{0}//:{1}".format(*it) for it in build_deps],
                        # FIXME: Check annotations
                        is_native = False,
                        version = package["version"],
                    )

                    has_sbuild = True

                install_cfgs[k] = struct(
                    whls = {whl["url"].split("/")[-1].split("?")[0].split("#")[0]: bdist_table.get(whl["hash"]) for whl in package.get("wheels", [])},
                    sbuild = "@{}//:whl".format(sbuild_id) if has_sbuild else None,
                )

            # Frustratingly we have to re-key all these structures so that they
            # can be jsonified later. Note that the _key is a structured string
            # which we can re-parse on the other side (sigh) so we DO NOT mangle
            # them at all. Mangling will be done as needed on the other side(s).
            #
            # FIXME: Can we make a re-keying helper?
            project_cfgs[project_id] = struct(
                dep_to_scc = marked_package_cfg_sccs,
                scc_deps = {
                    k: {
                        d[1]: markers
                        for d, markers in deps.items()
                    }
                    for k, deps in scc_deps.items()
                },
                scc_graph = {
                    scc_id: {
                        install_table[m]: markers
                        for m, markers in members.items()
                        # Extras etc. have no install table presence
                        if m in install_table
                    }
                    for scc_id, members in scc_graph.items()
                },
            )

            hub_cfg = hub_cfgs.setdefault(project.hub_name, struct(
                configurations = {},
                packages = {},
            ))

            for cfg in configuration_names.keys():
                if cfg in hub_cfg.configurations:
                    fail("Conflict on configuration name {} in hub {}".format(cfg, project.hub_name))

            # Build a mapping from configurations to the project containing that configuration
            hub_cfg.configurations.update({
                name: project_id
                for name in configuration_names.keys()
            })

            # Build a {requirement: {cfg: target mapping}}
            for package, cfgs in version_activations.items():
                for cfg in cfgs.keys():
                    hub_cfg.packages.setdefault(package, {})[cfg] = "@{}//:{}".format(project_id, package)

    return struct(
        project_cfgs = project_cfgs,
        hub_cfgs = hub_cfgs,
        install_cfgs = install_cfgs,
        sbuild_cfgs = sbuild_specs,
        marker_cfgs = marker_specs,
        whl_cfgs = whl_configurations,
        sdist_cfgs = sdist_specs,
        bdist_cfgs = bdist_specs,
    )

def _uv_impl(module_ctx):
    """The implementation function for the `uv` module extension.

    This function is the main entry point for the module extension. It orchestrates
    the entire dependency resolution process, which includes:
    - Parsing `uv.hub()` and `uv.project()` declarations.
    - Generating repository rules for fetching and building all the declared
      dependencies.
    - Generating a `uv_project` repository rule for each pyproject.toml, which
      contains the resolved dependency graph for that project according to the
      matching lockfile.
    - Generating a `uv_hub` repository rule for each hub, which contains the
      aggregated dependency information for all the projects in that hub.

    Args:
        module_ctx: The Bazel module context.
    """

    hub_specs = _parse_hubs(module_ctx)

    cfg = _parse_projects(module_ctx, hub_specs)

    configurations_hub(
        name = "aspect_rules_py_pip_configurations",
        configurations = cfg.whl_cfgs,
        markers = {},
    )

    for sdist_name, sdist_cfg in cfg.sdist_cfgs.items():
        if "file" in sdist_cfg:
            sdist_cfg = sdist_cfg["file"]
            sha256 = None
            if "hash" in sdist_cfg:
                sha256 = sdist_cfg["hash"][len("sha256:"):]

            http_file(
                name = sdist_name,
                url = sdist_cfg["url"],
                sha256 = sha256,
                downloaded_file_path = sdist_cfg["url"].split("/")[-1].split("?")[0].split("#")[0],
            )

        elif "git" in sdist_cfg:
            git_cfg = sdist_cfg["git"]
            git_archive(
                name = sdist_name,
                remote = git_cfg["remote"],
                commit = git_cfg.get("commit"),
                ref = git_cfg.get("ref"),
            )

        else:
            fail("Unsupported archive! {}".format(repr(sdist_cfg)))

    for bdist_name, bdist_cfg in cfg.bdist_cfgs.items():
        http_file(
            name = bdist_name,
            url = bdist_cfg["url"],
            sha256 = bdist_cfg["hash"][len("sha256:"):],
            downloaded_file_path = bdist_cfg["url"].split("/")[-1].split("?")[0].split("#")[0],
        )

    for sbuild_id, sbuild_cfg in cfg.sbuild_cfgs.items():
        sdist_build(
            name = sbuild_id,
            src = sbuild_cfg.src,
            deps = sbuild_cfg.deps,
            is_native = sbuild_cfg.is_native,
            version = sbuild_cfg.version,
        )

    for install_id, install_cfg in cfg.install_cfgs.items():
        whl_install(
            name = install_id,
            sbuild = install_cfg.sbuild,
            whls = json.encode(install_cfg.whls),
        )

    for project_id, project_cfg in cfg.project_cfgs.items():
        uv_project(
            name = project_id,
            dep_to_scc = json.encode(project_cfg.dep_to_scc),
            scc_deps = json.encode(project_cfg.scc_deps),
            scc_graph = json.encode(project_cfg.scc_graph),
        )

    for hub_id, hub_cfg in cfg.hub_cfgs.items():
        uv_hub(
            name = hub_id,
            configurations = hub_cfg.configurations,
            packages = json.encode(hub_cfg.packages),
        )

    if features.external_deps.extension_metadata_has_reproducible:
        return module_ctx.extension_metadata(reproducible = True)

_hub_tag = tag_class(
    attrs = {
        "hub_name": attr.string(mandatory = True),
    },
)

_project_tag = tag_class(
    attrs = {
        "hub_name": attr.string(mandatory = True),
        "name": attr.string(mandatory = False),
        "version": attr.string(mandatory = False),
        "pyproject": attr.label(mandatory = True),
        "lock": attr.label(mandatory = True),
        "elide_sbuilds_with_anyarch": attr.bool(mandatory = False, default = True),
        "default_build_dependencies": attr.string_list(
            mandatory = False,
            default = [
                "build",
                "setuptools",
            ],
        ),
    },
)

_annotations_tag = tag_class(
    attrs = {
        "lock": attr.label(mandatory = True),
        "src": attr.label(mandatory = True),
    },
)

_declare_entrypoint_tag = tag_class(
    attrs = {
        "package": attr.string(mandatory = True),
        "version": attr.string(mandatory = False),
        "name": attr.string(mandatory = True),
        "entrypoint": attr.string(mandatory = True),
    },
)

_override_package_tag = tag_class(
    attrs = {
        "lock": attr.label(mandatory = True),
        "name": attr.string(mandatory = True),
        "version": attr.string(mandatory = False),
        "target": attr.label(mandatory = True),
    },
)

# TODO: patch_package

uv = module_extension(
    implementation = _uv_impl,
    tag_classes = {
        "declare_hub": _hub_tag,
        "project": _project_tag,
        "unstable_annotate_packages": _annotations_tag,
        "override_package": _override_package_tag,
        # "declare_entrypoint": _declare_entrypoint_tag,
    },
)
