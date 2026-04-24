"""A Bazel module extension for resolving Python dependencies from a `uv.lock` file.

This extension translates a `uv.lock` file into Bazel repository rules. It reads
dependency metadata from `pyproject.toml` and `uv.lock`, builds a dependency graph,
evaluates PEP 508 environment markers, detects cyclic dependencies via strongly
connected components (SCCs), and generates the necessary repositories to fetch
pre-built wheels or build wheels from source.

Supported scenarios:
- Cross-platform dependency resolution (different OS/arch combinations).
- Hermetic source distribution (sdist) builds.
- Cyclic dependency handling through SCC decomposition.

## Example (MODULE.bazel)

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

The `use_repo` call exposes all resolved packages under the `@uv` repository.

## Common Types

- **Dependency:** A tuple `(project_id, package_name, version, extra)` that uniquely
  identifies a package inside a lockfile. `extra` is `__base__` when no extra is
  active.
- **Marker:** A PEP 508 marker string (e.g. `"sys_platform == 'linux'"`).
- **SCC:** A Strongly Connected Component — a set of packages with mutual
  dependency cycles.

## References

[1] https://peps.python.org/pep-0751/
[2] https://peps.python.org/pep-0751/#locking-build-requirements-for-sdists
"""

load("@bazel_features//:features.bzl", features = "bazel_features")
load("@bazel_skylib//lib:sets.bzl", "sets")
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")
load("//py/private/interpreter:resolve.bzl", "resolve_host_interpreter_label")
load("//uv/private:normalize_name.bzl", "normalize_name")
load("//uv/private/constraints:repository.bzl", "configurations_hub")
load("//uv/private/git_archive:repository.bzl", "git_archive")
load("//uv/private/pprint:defs.bzl", "pprint")
load("//uv/private/sdist_build:repository.bzl", "sdist_build")
load("//uv/private/sdist_configure:defs.bzl", "DEFAULT_CONFIGURE_SCRIPT")
load("//uv/private/tomltool:toml.bzl", "toml")
load("//uv/private/uv_hub:repository.bzl", "uv_hub")
load("//uv/private/uv_project:repository.bzl", "uv_project")
load("//uv/private/whl_install:repository.bzl", "whl_install")
load(":graph_utils.bzl", "activate_extras", "collect_sccs")
load(":lockfile.bzl", "build_marker_graph", "collect_bdists", "collect_configurations", "collect_markers", "collect_sdists", "normalize_deps")
load(":projectfile.bzl", "collate_versions_by_name", "collect_activated_extras", "extract_requirement_marker_pairs")

def _merge_scc_dep_markers_by_surface_package(marked_deps):
    """Merges markers for SCC external deps that share the same surface package name.

    SCC external deps are keyed by the fully versioned lock tuple, but the
    generated hub targets depend on the surface package alias. Merging markers
    for all versions ensures that split dependencies preserve their full platform
    coverage instead of overwriting each other.

    Args:
        marked_deps: A dictionary mapping dependency tuples to marker dicts.

    Returns:
        A dictionary mapping package names to merged marker dicts.
    """
    merged = {}
    for dep, markers in marked_deps.items():
        merged.setdefault(dep[1], {}).update(markers)
    return merged

def _parse_hubs(module_ctx):
    """Parses `uv.declare_hub()` declarations from all modules.

    Iterates through all modules in the Bazel dependency graph and collects the
    `uv.declare_hub()` declarations, including the list of target platforms
    for which wheels should be downloaded.

    Args:
        module_ctx: The Bazel module context.

    Returns:
        A dictionary of hub specifications, where the keys are hub names and the
        values are structs with fields `modules` and `target_platforms`.
    """
    hub_specs = {}

    for mod in module_ctx.modules:
        for hub in mod.tags.declare_hub:
            if hub.hub_name not in hub_specs:
                hub_specs[hub.hub_name] = struct(
                    modules = {},
                    target_platforms = list(hub.target_platforms),
                )
            hub_specs[hub.hub_name].modules[mod.name] = 1
            for p in hub.target_platforms:
                if p not in hub_specs[hub.hub_name].target_platforms:
                    hub_specs[hub.hub_name].target_platforms.append(p)

    return hub_specs

def _parse_projects(module_ctx, hub_specs):
    """Parses all `uv.project()` declarations from all modules.

    This is the core of the module extension's logic. It iterates through all
    `uv.project()` declarations, parses the `pyproject.toml` and `uv.lock`
    files, and builds the complete dependency graph, artifact tables, and build
    configurations.

    Args:
        module_ctx: The Bazel module context.
        hub_specs: A dictionary of hub specifications, as returned by
            `_parse_hubs`.

    Returns:
        A struct containing all parsed information, including dependency graphs,
        SCCs, and configurations for all generated repository rules.
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

    for mod in module_ctx.modules:
        for project in mod.tags.project:
            project_data = toml.decode_file(module_ctx, project.pyproject)
            lock_data = toml.decode_file(module_ctx, project.lock)

            project_stamp = normalize_name(project_data["project"]["name"])
            project_id = "project__" + project_stamp

            project_name = project.name or project_data["project"]["name"]
            project_version = project.version or project_data["project"]["version"]

            if project.hub_name not in hub_specs:
                fail("Project {} in {} refers to hub {} which is not configured for that module. Please declare it.".format(project_name, mod.name, project.hub_name))

            hub_target_platforms = hub_specs[project.hub_name].target_platforms

            if lock_data == None or not lock_data.get("package"):
                print("WARNING: uv.lock not found or invalid for project '{}'. Run 'uv lock' to generate it.".format(project_name))
                hub_cfgs.setdefault(project.hub_name, struct(
                    configurations = {},
                    packages = {},
                    python_version = project.python_version,
                    target_platforms = hub_target_platforms,
                ))
                continue

            no_binary_packages = {
                normalize_name(p): True
                for p in project_data.get("tool", {}).get("uv", {}).get("no-binary-package", [])
            }

            default_versions, package_versions, lock_data = normalize_deps(project_id, lock_data)

            if default_versions == None:
                print("WARNING: uv.lock is structurally invalid for project '{}'. Run 'uv lock' to regenerate it.".format(project_name))
                hub_cfgs.setdefault(project.hub_name, struct(
                    configurations = {},
                    packages = {},
                    python_version = project.python_version,
                    target_platforms = hub_target_platforms,
                ))
                continue

            def _resolve(package, fail_if_missing = True):
                name = normalize_name(package["name"])
                if "version" in package:
                    return (project_id, name, package["version"], "__base__")
                elif name in default_versions:
                    return default_versions[name]
                else:
                    if fail_if_missing:
                        fail("Unable to identify id for package {} for lock {}\n{}".format(package, project.lock, pprint(default_versions)))
                    return None

            lock_build_dep_anns = {}
            for ann in mod.tags.unstable_annotate_packages:
                if ann.lock == project.lock:
                    annotations = toml.decode_file(module_ctx, ann.src)
                    for package in annotations.get("package", []):
                        k = _resolve(package, fail_if_missing = False)
                        if k == None:
                            continue
                        deps = []
                        skip = False
                        for dep in package.get("build-dependencies", []):
                            resolved = _resolve(dep, fail_if_missing = False)
                            if resolved == None:
                                skip = True
                                break
                            deps.append(resolved)
                        if not skip:
                            lock_build_dep_anns[k] = deps

            package_overrides = {}
            for override in mod.tags.override_package:
                if override.lock != project.lock:
                    continue

                v = override.version or default_versions.get(normalize_name(override.name), (None, None, None, None))[2]
                if not v:
                    fail("Overridden project {} neither specifies a version nor has an implied singular version in the lockfile!".format(override.name, project.lock))

                override_key = (normalize_name(override.name), v)
                if override_key in package_overrides:
                    fail("Duplicate uv.override_package() for package '{}' version '{}' in lock '{}'. Each (lock, name, version) triple may only be overridden once.".format(
                        override.name,
                        v,
                        project.lock,
                    ))

                has_target = override.target != None
                has_modifications = (
                    override.pre_build_patches or
                    override.post_install_patches or
                    override.extra_deps or
                    override.extra_data
                )

                if has_target and has_modifications:
                    fail("uv.override_package() for '{}': `target` is mutually exclusive with patch/exclude attributes. Use `target` for full replacement OR patch/exclude attributes for modifications, not both.".format(override.name))

                if not has_target and not has_modifications:
                    fail("uv.override_package() for '{}': must specify either `target` for full replacement or at least one modification attribute (pre_build_patches, post_install_patches, extra_deps, extra_data).".format(override.name))

                package_overrides[override_key] = override

                k = (project_id, normalize_name(override.name), v, "__base__")
                if has_target:
                    print("Overriding {}@{} in {} with {}".format(override.name, v, project_name, override.target))
                    install_table[k] = str(override.target)

            lock_build_deps = None

            marker_graph = build_marker_graph(project_id, lock_data)

            marker_specs.update(collect_markers(marker_graph))

            bd, bt = collect_bdists(lock_data, hub_target_platforms)
            bdist_specs.update(bd)
            bdist_table.update(bt)

            sd, st = collect_sdists(project_stamp, lock_data)
            sdist_specs.update(sd)
            sdist_table.update(st)

            whl_configurations.update(collect_configurations(lock_data, hub_target_platforms))

            configuration_names, activated_extras = collect_activated_extras(project.lock, project_id, project_data, lock_data, default_versions, marker_graph, package_versions)
            version_activations = collate_versions_by_name(activated_extras)

            scc_graph = {}
            scc_deps = {}
            package_cfg_sccs = {}
            for cfg in configuration_names:
                cfgd_marker_graph = activate_extras(marker_graph, activated_extras, cfg)
                cfgd_dep_to_scc, cfgd_scc_graph, cfgd_scc_deps = collect_sccs(cfgd_marker_graph)

                scc_graph.update(cfgd_scc_graph)
                scc_deps.update(cfgd_scc_deps)

                for package, scc in cfgd_dep_to_scc.items():
                    package_cfg_sccs.setdefault(package, {})[cfg] = scc

            marked_package_cfg_sccs = {}
            for package, cfgs in version_activations.items():
                for cfg, versions in cfgs.items():
                    for version, markers in versions.items():
                        marked_package_cfg_sccs.setdefault(package, {}).setdefault(cfg, {}).setdefault(package_cfg_sccs[version][cfg], {}).update(markers)

            project_available_deps = {}
            for package in lock_data.get("package", []):
                if "editable" in package.get("source", {}) or "virtual" in package.get("source", {}):
                    continue
                pkg_name = normalize_name(package["name"])
                pkg_stamp = "whl_install__{}__{}__{}".format(
                    project_stamp,
                    package["name"],
                    package["version"].replace(".", "_"),
                )
                project_available_deps[pkg_name] = "@{}//:install".format(pkg_stamp)

            for package in lock_data.get("package", []):
                install_key = (project_id, package["name"], package["version"], "__base__")
                if install_key in install_table:
                    continue
                elif "editable" in package["source"] or "virtual" in package["source"]:
                    if normalize_name(package["name"]) == normalize_name(project_name):
                        continue
                    else:
                        fail("Virtual package {} in lockfile {} doesn't have a mandatory `uv.override_package()` annotation!".format(package["name"], project.lock))

                k = "whl_install__{}__{}__{}".format(project_stamp, package["name"], package["version"].replace(".", "_"))
                install_table[install_key] = "@{}//:install".format(k)
                sbuild_id = "sdist_build__{}__{}__{}".format(project_stamp, package["name"], package["version"].replace(".", "_"))
                sdist = sdist_table.get(sbuild_id)

                has_sbuild = False

                is_no_binary = normalize_name(package["name"]) in no_binary_packages

                has_any_wheel = len(package.get("wheels", [])) > 0
                if is_no_binary and not sdist:
                    fail("Package {} is in [tool.uv] no-binary-package but has no sdist in the lockfile".format(package["name"]))
                if sdist and (is_no_binary or not has_any_wheel):
                    ann_key = (project_id, normalize_name(package["name"]), package["version"], "__base__")
                    build_deps = lock_build_dep_anns.get(ann_key) or []
                    if lock_build_deps == None:
                        base_build_deps = [
                            it[0]
                            for req in project.default_build_dependencies
                            for it in extract_requirement_marker_pairs(project.lock, project_id, req, default_versions, package_versions)
                        ]

                        package_deps = {}
                        for pkg in lock_data.get("package", []):
                            package_deps[(normalize_name(pkg["name"]), pkg["version"])] = [
                                normalize_name(dep["name"])
                                for dep in pkg.get("dependencies", [])
                            ]
                        lock_build_deps = []
                        visited = {}
                        worklist = list(base_build_deps)
                        for _ in range(1000):
                            if len(worklist) == 0:
                                break
                            dep_tuple = worklist.pop(0)
                            if dep_tuple in visited:
                                continue
                            visited[dep_tuple] = True
                            lock_build_deps.append(dep_tuple)
                            for child_name in package_deps.get((dep_tuple[1], dep_tuple[2]), []):
                                child_versions = package_versions.get(child_name, {})
                                if len(child_versions) == 1:
                                    child_tuple = (project_id, child_name, list(child_versions)[0], "__base__")
                                    worklist.append(child_tuple)

                    build_deps = sets.to_list(sets.make(build_deps + lock_build_deps))

                    pkg_override = package_overrides.get((normalize_name(package["name"]), package["version"]))
                    pre_build_patches = []
                    pre_build_patch_strip = 0
                    if pkg_override and pkg_override.pre_build_patches:
                        pre_build_patches = [str(p) for p in pkg_override.pre_build_patches]
                        pre_build_patch_strip = pkg_override.pre_build_patch_strip

                    sbuild_specs[sbuild_id] = struct(
                        src = sdist,
                        deps = [project_available_deps.get(it[1], "@{0}//:{1}".format(*it)) for it in build_deps],
                        is_native = "auto",
                        version = package["version"],
                        python_version = project.python_version,
                        pre_build_patches = pre_build_patches,
                        pre_build_patch_strip = pre_build_patch_strip,
                        available_deps = project_available_deps,
                        configure_command = project.unstable_configure_command,
                    )

                    has_sbuild = True

                pkg_override = package_overrides.get((normalize_name(package["name"]), package["version"]))
                post_install_patches = []
                post_install_patch_strip = 0
                extra_deps = []
                extra_data = []
                if pkg_override and not pkg_override.target:
                    post_install_patches = [str(p) for p in pkg_override.post_install_patches]
                    post_install_patch_strip = pkg_override.post_install_patch_strip
                    extra_deps = [str(d) for d in pkg_override.extra_deps]
                    extra_data = [str(d) for d in pkg_override.extra_data]

                install_cfgs[k] = struct(
                    whls = {} if is_no_binary else {
                        whl["url"].split("/")[-1].split("?")[0].split("#")[0]: bdist_table[whl["hash"]]
                        for whl in package.get("wheels", [])
                        if whl["hash"] in bdist_table
                    },
                    sbuild = "@{}//:whl".format(sbuild_id) if has_sbuild else None,
                    post_install_patches = post_install_patches,
                    post_install_patch_strip = post_install_patch_strip,
                    extra_deps = extra_deps,
                    extra_data = extra_data,
                    target_platforms = hub_target_platforms,
                )

            project_cfgs[project_id] = struct(
                dep_to_scc = marked_package_cfg_sccs,
                scc_deps = {
                    k: {
                        dep_name: markers
                        for dep_name, markers in _merge_scc_dep_markers_by_surface_package(
                            deps,
                        ).items()
                    }
                    for k, deps in scc_deps.items()
                },
                scc_graph = {
                    scc_id: {
                        install_table[m]: markers
                        for m, markers in members.items()
                        if m in install_table
                    }
                    for scc_id, members in scc_graph.items()
                },
            )

            hub_cfg = hub_cfgs.setdefault(project.hub_name, struct(
                configurations = {},
                packages = {},
                python_version = project.python_version,
                target_platforms = hub_target_platforms,
            ))

            for cfg in configuration_names.keys():
                if cfg in hub_cfg.configurations:
                    fail("Conflict on configuration name {} in hub {}".format(cfg, project.hub_name))

            hub_cfg.configurations.update({
                name: project_id
                for name in configuration_names.keys()
            })

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

def uv_impl(module_ctx):
    """The implementation function for the `uv` module extension.

    Orchestrates the entire dependency resolution process, which includes:
    - Parsing `uv.hub()` and `uv.project()` declarations.
    - Generating repository rules for fetching and building dependencies.
    - Generating a `uv_project` repository rule for each project.
    - Generating a `uv_hub` repository rule for each hub.

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
        sha256 = None
        if "hash" in bdist_cfg:
            sha256 = bdist_cfg["hash"][len("sha256:"):]

        http_file(
            name = bdist_name,
            url = bdist_cfg["url"],
            sha256 = sha256,
            downloaded_file_path = bdist_cfg["url"].split("/")[-1].split("?")[0].split("#")[0],
        )

    default_configure_interpreter = resolve_host_interpreter_label(module_ctx)
    default_configure_command = []
    if default_configure_interpreter:
        default_configure_command = [
            "$(location {})".format(default_configure_interpreter),
            "$(location {})".format(DEFAULT_CONFIGURE_SCRIPT),
        ]

    for sbuild_id, sbuild_cfg in cfg.sbuild_cfgs.items():
        sbuild_kwargs = {
            "name": sbuild_id,
            "src": sbuild_cfg.src,
            "deps": sbuild_cfg.deps,
            "is_native": sbuild_cfg.is_native,
            "version": sbuild_cfg.version,
            "python_version": sbuild_cfg.python_version,
        }

        if sbuild_cfg.configure_command:
            sbuild_kwargs["configure_command"] = sbuild_cfg.configure_command
        elif default_configure_command:
            sbuild_kwargs["configure_command"] = default_configure_command

        if sbuild_cfg.available_deps:
            sbuild_kwargs["available_deps"] = json.encode(sbuild_cfg.available_deps)
        if sbuild_cfg.pre_build_patches:
            sbuild_kwargs["pre_build_patches"] = sbuild_cfg.pre_build_patches
            sbuild_kwargs["pre_build_patch_strip"] = sbuild_cfg.pre_build_patch_strip
        sdist_build(**sbuild_kwargs)

    for install_id, install_cfg in cfg.install_cfgs.items():
        install_kwargs = {
            "name": install_id,
            "sbuild": install_cfg.sbuild,
            "whls": json.encode(install_cfg.whls),
        }
        if install_cfg.post_install_patches:
            install_kwargs["post_install_patches"] = json.encode(install_cfg.post_install_patches)
            install_kwargs["post_install_patch_strip"] = install_cfg.post_install_patch_strip
        if install_cfg.extra_deps:
            install_kwargs["extra_deps"] = json.encode(install_cfg.extra_deps)
        if install_cfg.extra_data:
            install_kwargs["extra_data"] = json.encode(install_cfg.extra_data)
        if install_cfg.target_platforms:
            install_kwargs["target_platforms"] = json.encode(install_cfg.target_platforms)
        whl_install(**install_kwargs)

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
            python_version = hub_cfg.python_version,
            target_platforms = json.encode(hub_cfg.target_platforms),
        )

    if not features.external_deps.extension_metadata_has_reproducible:
        return None
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
        "python_version": attr.string(
            mandatory = True,
            doc = "Python version to use for uv lock resolution (e.g. '3.11').",
        ),
        "pyproject": attr.label(mandatory = True),
        "lock": attr.label(mandatory = True),
        "elide_sbuilds_with_anyarch": attr.bool(mandatory = False, default = True),
        "default_build_dependencies": attr.string_list(
            mandatory = False,
            default = [
                "build",
            ],
        ),
        "unstable_configure_command": attr.string_list(
            mandatory = False,
            doc = "Command to run as the sdist configure tool. Each element is either " +
                  "a literal string argument or a $(location <label>) expansion. " +
                  "The archive path and context file are appended as the final two " +
                  "arguments. When set, replaces the default native-detection tool. " +
                  "See //uv/private/sdist_configure:defs.bzl for the contract.",
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
        "target": attr.label(mandatory = False),
        "pre_build_patches": attr.label_list(
            default = [],
            allow_files = [".patch", ".diff"],
            doc = "Patch files to apply to the sdist source tree before building a wheel.",
        ),
        "pre_build_patch_strip": attr.int(
            default = 0,
            doc = "Strip count for pre-build patches (-p flag to the patch tool).",
        ),
        "post_install_patches": attr.label_list(
            default = [],
            allow_files = [".patch", ".diff"],
            doc = "Patch files to apply to the installed package after wheel unpacking.",
        ),
        "post_install_patch_strip": attr.int(
            default = 0,
            doc = "Strip count for post-install patches (-p flag to the patch tool).",
        ),
        "extra_deps": attr.label_list(
            default = [],
            doc = "Additional deps to add to the package's py_library target.",
        ),
        "extra_data": attr.label_list(
            default = [],
            doc = "Additional data files to add to the package's py_library target.",
        ),
    },
    doc = """Override or modify a Python package resolved from a lockfile.

Use `target` for full replacement, or use the patch/exclude attributes
for surgical modifications. Specifying `target` is mutually exclusive with
all other modification attributes.""",
)

uv = module_extension(
    implementation = uv_impl,
    tag_classes = {
        "declare_hub": _hub_tag,
        "project": _project_tag,
        "unstable_annotate_packages": _annotations_tag,
        "override_package": _override_package_tag,
    },
)
