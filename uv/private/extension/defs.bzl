"""A Bazel module extension that resolves Python dependencies from a `uv.lock`.

Reads a `pyproject.toml` and its companion `uv.lock`, builds a dependency graph
annotated with PEP 508 markers, and generates repository rules to fetch
pre-built wheels or build wheels from source distributions.

Handled scenarios:
- Cross-platform builds across OS/arch combinations.
- Hermetic builds of source distributions.
- Dependency cycles, collapsed by computing the strongly connected components
  (SCCs) of the dependency graph.

## Example

```starlark
uv = use_extension("@aspect_rules_py//uv:extension.bzl", "uv")
uv.declare_hub(hub_name = "uv")
uv.project(
    hub_name = "uv",
    name = "my_project",
    pyproject = "//:pyproject.toml",
    lock = "//:uv.lock",
)
use_repo(uv, "uv")
```

`use_repo` then exposes the resolved dependencies under `@uv`.

## Common types

- **Dependency:** `(project_id, package_name, version, extra)` tuple keying a
  package within a lockfile; `extra` is the optional extra name, or `__base__`
  for the base package.
- **Marker:** A PEP 508 marker string gating an edge on environment
  (e.g. `"sys_platform == 'linux'"`); `""` is the always-true marker.
- **SCC:** A strongly connected component: mutually cyclic packages collapsed
  into a single install target.

[1] https://peps.python.org/pep-0751/
[2] https://peps.python.org/pep-0751/#locking-build-requirements-for-sdists
"""

load("@bazel_features//:features.bzl", features = "bazel_features")
load("@bazel_lib//lib:resource_sets.bzl", "resource_set_values")
load("@bazel_skylib//lib:sets.bzl", "sets")
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")
load("//py/private/interpreter:resolve.bzl", "resolve_host_interpreter_label")
load("//uv/private:normalize_name.bzl", "normalize_name")
load("//uv/private:normalize_version.bzl", "normalize_version")
load("//uv/private:parse_whl_name.bzl", "parse_whl_name")
load("//uv/private/constraints:repository.bzl", "configurations_hub")
load("//uv/private/git_archive:repository.bzl", "git_archive")
load("//uv/private/sdist_build:attrs.bzl", "validate_build_attrs")
load("//uv/private/sdist_build:repository.bzl", "sdist_build")
load("//uv/private/sdist_configure:defs.bzl", "DEFAULT_CONFIGURE_SCRIPT")
load("//uv/private/tomltool:toml.bzl", "toml")
load("//uv/private/uv_hub:repository.bzl", "uv_hub")
load("//uv/private/uv_project:repository.bzl", "uv_project")
load("//uv/private/whl_install:repository.bzl", "parse_console_script", "whl_install")
load(":graph_utils.bzl", "activate_extras", "collect_sccs")
load(":lockfile.bzl", "build_marker_graph", "collect_bdists", "collect_configurations", "collect_sdists", "normalize_deps", "url_basename")
load(":projectfile.bzl", "collate_versions_by_name", "collect_activated_extras", "extract_requirement_marker_pairs")

def _dist_sha256(dist):
    """The distribution's sha256 for `http_file`, or None for other algorithms."""
    hash = dist.get("hash", "")
    return hash[len("sha256:"):] if hash.startswith("sha256:") else None

def _deduplicate_whl_files(whls):
    """Return unique non-empty wheel labels, preserving order."""
    whl_files = []
    seen = {}
    for whl in whls:
        if not whl or whl in seen:
            continue
        seen[whl] = True
        whl_files.append(whl)
    return whl_files

def parse_declared_console_script(name, entry_point):
    """Canonicalize one `override_package` console-script declaration.

    Args:
        name: Script name installed under the venv's bin directory.
        entry_point: Python entry point encoded as `module:object`.

    Returns:
        The canonical `name=module:object` string, or None when invalid.
    """
    whitespace = [" ", "\t", "\n", "\r"]
    if (
        name in ("", ".", "..") or
        "/" in name or
        "\\" in name or
        "=" in name or
        "=" in entry_point or
        "[" in entry_point or
        "]" in entry_point or
        len(entry_point.split(":")) != 2 or
        any([char in name or char in entry_point for char in whitespace])
    ):
        return None
    parsed = parse_console_script("{}={}".format(name, entry_point))
    return parsed[1] if parsed != None else None

def _merge_scc_dep_markers_by_surface_package(marked_deps):
    """Merge SCC external-dep markers onto surface-package keys.

    SCC external deps are keyed by the fully versioned lock tuple, but the
    generated hub targets key on the surface package alias. Merging markers
    across versions preserves full platform coverage for split dependencies
    (e.g. chdb -> pyarrow) instead of letting one version overwrite another.
    """
    merged = {}
    for dep, markers in marked_deps.items():
        merged.setdefault(dep[1], {}).update(markers)
    return merged

def _parse_hubs(module_ctx):
    """Collect `uv.declare_hub()` declarations across all modules.

    Hub names are globally unique, but a single hub name may be registered from
    multiple modules: a conventional hub like `@pypi` can be referenced widely,
    since build configuration is disambiguated per venv, not per hub.

    Args:
        module_ctx: The Bazel module context.

    Returns:
        A dict of declared hub names, used to validate project registrations.
    """
    hub_specs = {}
    for mod in module_ctx.modules:
        for hub in mod.tags.declare_hub:
            hub_specs[hub.hub_name] = True
    return hub_specs

def _parse_projects(module_ctx, hub_specs):
    """Parse every `uv.project()` declaration into the full dependency model.

    For each project, reads its `pyproject.toml` and `uv.lock`, normalizes
    versions, resolves the extras activated per configuration group, collapses
    cyclic dependencies into SCCs, and produces the install/sdist/bdist/build
    catalogs consumed by `_uv_impl`.

    Design rationale (kept here instead of inline):

    - Build dependencies resolve lazily so bdist-only projects never have to
      supply `default_build_dependencies`. Resolution fails eagerly only when
      an sdist build is guaranteed (a `no-binary-package` override or an
      sdist-only package with no wheels); platform mismatches are undetectable
      here because the target build platform is unknown.
      TODO: defer `[build-system] requires` introspection to the repo rule.
      TODO: collect build-deps annotation files.
    - `uv` may emit several lock records for one package/version
      (resolution-marker forks), each with a different wheel subset; records are
      merged per install rather than overwritten.
    - All wheels of a package/version extract the same
      `<project>-<version>.dist-info` directory; its name is derived from the
      wheel filename and asserted consistent across wheels.
    - `available_deps` is pre-computed per project to give the sdist configure
      tool visibility into the project's full dependency perimeter.
    - SCC ids are interned across configurations: identical content reuses one
      id; content differing only in external deps/markers stays distinct.
      Per-configuration markers are aggregated into one graph, a deliberate
      simplification when markers diverge across configured graphs.
    - The package loop resets `has_sbuild` each iteration and only sets it when
      a build is configured.
    - SCC and install structures are re-keyed to JSON strings without mangling
      the structured keys, which are re-parsed downstream.
      TODO: extract a re-keying helper.

    Args:
        module_ctx: The Bazel module context.
        hub_specs: Declared hub names, as returned by `_parse_hubs`.

    Returns:
        A struct of catalogs (`project_cfgs`, `hub_cfgs`, `install_cfgs`,
        `sbuild_cfgs`, `whl_cfgs`, `sdist_cfgs`, `bdist_cfgs`) describing every
        repository rule to generate.
    """

    hub_cfgs = {}
    project_cfgs = {}
    whl_configurations = {}

    sdist_specs = {}
    sdist_table = {}

    bdist_specs = {}
    bdist_table = {}

    sbuild_specs = {}

    install_cfgs = {}
    install_table = {}

    for mod in module_ctx.modules:
        project_locks = {project.lock: True for project in mod.tags.project}
        for override in mod.tags.override_package:
            if override.lock not in project_locks:
                fail("uv.override_package() for '{}' refers to lock '{}', but module '{}' has no uv.project() for that lock.".format(
                    override.name,
                    override.lock,
                    mod.name,
                ))

        for project in mod.tags.project:
            project_data = toml.decode_file(module_ctx, project.pyproject)
            lock_data = toml.decode_file(module_ctx, project.lock)

            project_stamp = normalize_name(project_data["project"]["name"])
            project_id = "project__" + project_stamp

            project_name = project.name or project_data["project"]["name"]

            if project.hub_name not in hub_specs:
                fail("Project {} in {} refers to hub {} which is not configured for that module. Please declare it.".format(project_name, mod.name, project.hub_name))

            no_binary_packages = {
                normalize_name(p): True
                for p in project_data.get("tool", {}).get("uv", {}).get("no-binary-package", [])
            }

            default_versions, package_versions, lock_data = normalize_deps(project_id, lock_data)

            def _resolve(package):
                name = normalize_name(package["name"])
                if "version" in package:
                    return (project_id, name, package["version"], "__base__")
                elif name in default_versions:
                    return default_versions[name]
                return None

            lock_build_dep_anns = {}
            lock_native_anns = {}
            for ann in mod.tags.unstable_annotate_packages:
                if ann.lock == project.lock:
                    annotations = toml.decode_file(module_ctx, ann.src)
                    for package in annotations.get("package", []):
                        k = _resolve(package)
                        if k == None:
                            continue
                        if "native" in package:
                            if type(package["native"]) != "bool":
                                fail("Annotation `native` for package {} in {} must be a boolean, got {}".format(package["name"], ann.src, repr(package["native"])))
                            lock_native_anns[k] = package["native"]
                        if "build-dependencies" in package:
                            deps = []
                            skip = False
                            for dep in package["build-dependencies"]:
                                resolved = _resolve(dep)
                                if resolved == None:
                                    skip = True
                                    break
                                deps.append(resolved)
                            if not skip:
                                lock_build_dep_anns[k] = deps

            package_overrides = {}
            package_console_scripts = {}
            for override in mod.tags.override_package:
                if override.lock != project.lock:
                    continue

                name = normalize_name(override.name)
                v = override.version or default_versions.get(name, (None, None, None, None))[2]
                if not v:
                    fail("Overridden project {} neither specifies a version nor has an implied singular version in lock {}!".format(override.name, project.lock))
                available_versions = package_versions.get(name, {})
                if v not in available_versions:
                    fail("uv.override_package() for package '{}' selects version '{}', which is absent from lock '{}'; available versions: {}".format(
                        override.name,
                        v,
                        project.lock,
                        sorted(available_versions.keys()),
                    ))

                override_key = (name, v)
                if override_key in package_overrides:
                    fail("Duplicate uv.override_package() for package '{}' version '{}' in lock '{}'. Each (lock, name, version) triple may only be overridden once.".format(
                        override.name,
                        v,
                        project.lock,
                    ))

                console_scripts = []
                for raw_script_name, raw_entry_point in sorted(override.console_scripts.items()):
                    console_script = parse_declared_console_script(raw_script_name, raw_entry_point)
                    if console_script == None:
                        fail("uv.override_package() for '{}=={}' in lock '{}': `console_scripts` must map valid script names to `module:object` entry points; got {} = {}".format(
                            override.name,
                            v,
                            project.lock,
                            repr(raw_script_name),
                            repr(raw_entry_point),
                        ))
                    console_scripts.append(console_script)

                has_target = override.target != None
                if override.pre_build_patch_strip and not override.pre_build_patches:
                    fail("uv.override_package() for '{}': `pre_build_patch_strip` requires `pre_build_patches`.".format(override.name))
                if override.post_install_patch_strip and not override.post_install_patches:
                    fail("uv.override_package() for '{}': `post_install_patch_strip` requires `post_install_patches`.".format(override.name))
                has_modifications = (
                    override.console_scripts or
                    override.pre_build_patches or
                    override.post_install_patches or
                    override.extra_deps or
                    override.extra_data or
                    override.toolchains or
                    override.env or
                    override.monitor_memory or
                    override.resource_set != "default"
                )

                if has_target and has_modifications:
                    fail("uv.override_package() for '{}': `target` is mutually exclusive with modification attributes. Use `target` for full replacement OR build, patch, and data attributes for modifications, not both.".format(override.name))

                if not has_target and not has_modifications:
                    fail("uv.override_package() for '{}': must specify either `target` for full replacement or at least one modification attribute (console_scripts, pre_build_patches, post_install_patches, extra_deps, extra_data, toolchains, env, monitor_memory, resource_set).".format(override.name))

                package_overrides[override_key] = override
                package_console_scripts[override_key] = console_scripts

                k = (project_id, normalize_name(override.name), v, "__base__")
                if has_target:
                    if module_ctx.getenv("RULES_PY_UV_VERBOSE", ""):
                        print("Overriding {}@{} in {} with {}".format(override.name, v, project_name, override.target))
                    install_table[k] = str(override.target)

            lock_build_deps = None

            marker_graph = build_marker_graph(project_id, lock_data)

            bd, bt = collect_bdists(lock_data)
            bdist_specs.update(bd)
            bdist_table.update(bt)

            sd, st = collect_sdists(project_stamp, lock_data)
            sdist_specs.update(sd)
            sdist_table.update(st)

            whl_configurations.update(collect_configurations(lock_data))

            configuration_names, activated_extras = collect_activated_extras(project.lock, project_id, project_data, lock_data, default_versions, marker_graph, package_versions)
            version_activations = collate_versions_by_name(activated_extras)

            scc_graph = {}
            scc_deps = {}
            package_cfg_sccs = {}
            scc_id_state = {}
            for cfg in configuration_names:
                cfgd_marker_graph = activate_extras(marker_graph, activated_extras, cfg)
                cfgd_dep_to_scc, cfgd_scc_graph, cfgd_scc_deps = collect_sccs(cfgd_marker_graph, scc_id_state)

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
                    normalize_version(package["version"]),
                )
                project_available_deps[pkg_name] = "@{}//:install".format(pkg_stamp)

            for package in lock_data.get("package", []):
                install_key = (project_id, package["name"], package["version"], "__base__")
                k = "whl_install__{}__{}__{}".format(project_stamp, package["name"], normalize_version(package["version"]))
                install_target = "@{}//:install".format(k)
                existing_target = install_table.get(install_key)
                if existing_target != None and existing_target != install_target:
                    continue
                elif "virtual" in package["source"]:
                    override_key = (normalize_name(package["name"]), package["version"])
                    if override_key in package_overrides:
                        fail("Virtual package {} in lockfile {} cannot use a modification-only `uv.override_package()` annotation because it is not installed.".format(package["name"], project.lock))
                    continue
                elif "editable" in package["source"]:
                    if normalize_name(package["name"]) == normalize_name(project_name):
                        override_key = (normalize_name(package["name"]), package["version"])
                        if override_key in package_overrides:
                            fail("Editable project package {} in lockfile {} cannot use a modification-only `uv.override_package()` annotation because the workspace supplies it.".format(package["name"], project.lock))
                        continue
                    else:
                        fail("Editable package {} in lockfile {} doesn't have a mandatory `uv.override_package(target = ...)` annotation!".format(package["name"], project.lock))

                install_table[install_key] = install_target
                sbuild_id = "sdist_build__{}__{}__{}".format(project_stamp, package["name"], normalize_version(package["version"]))
                sdist = sdist_table.get(sbuild_id)
                override_key = (normalize_name(package["name"]), package["version"])
                pkg_override = package_overrides.get(override_key)
                sbuild_console_scripts = package_console_scripts.get(override_key, [])

                has_sbuild = False

                is_no_binary = normalize_name(package["name"]) in no_binary_packages

                if is_no_binary and not sdist:
                    fail("Package {} is in [tool.uv] no-binary-package but has no sdist in the lockfile".format(package["name"]))
                if pkg_override and not sdist:
                    validate_build_attrs(
                        console_scripts = sbuild_console_scripts,
                        resource_set = pkg_override.resource_set,
                        env = pkg_override.env,
                        error = "uv.override_package() for '{}=={}' in lock '{}': build-only attributes require a source distribution, but the lock record has only wheels: {{}}".format(
                            package["name"],
                            package["version"],
                            project.lock,
                        ),
                        monitor_memory = pkg_override.monitor_memory,
                        pre_build_patches = pkg_override.pre_build_patches,
                        pre_build_patch_strip = pkg_override.pre_build_patch_strip,
                        supported = [],
                        toolchains = pkg_override.toolchains,
                    )
                if sdist:
                    ann_key = (project_id, normalize_name(package["name"]), package["version"], "__base__")
                    build_deps = lock_build_dep_anns.get(ann_key) or []
                    is_native = "auto"
                    if ann_key in lock_native_anns:
                        is_native = "true" if lock_native_anns[ann_key] else "false"
                    if lock_build_deps == None:
                        sbuild_required = is_no_binary or not package.get("wheels", [])
                        lock_build_deps = [
                            it[0]
                            for req in project.default_build_dependencies
                            for it in extract_requirement_marker_pairs(project.lock, project_id, req, default_versions, package_versions, fail_if_missing = sbuild_required)
                        ]

                    build_deps = sets.to_list(sets.make(build_deps + lock_build_deps))

                    pre_build_patches = []
                    pre_build_patch_strip = 0
                    if pkg_override and pkg_override.pre_build_patches:
                        pre_build_patches = [str(p) for p in pkg_override.pre_build_patches]
                        pre_build_patch_strip = pkg_override.pre_build_patch_strip

                    extra_toolchains = []
                    extra_env = {}
                    monitor_memory = False
                    resource_set = "default"
                    if pkg_override:
                        extra_toolchains = [str(t) for t in pkg_override.toolchains]
                        extra_env = pkg_override.env
                        monitor_memory = pkg_override.monitor_memory
                        resource_set = pkg_override.resource_set

                    sbuild_specs[sbuild_id] = struct(
                        src = sdist,
                        deps = ["@{0}//:{1}".format(*it) for it in build_deps],
                        is_native = is_native,
                        version = package["version"],
                        pre_build_patches = pre_build_patches,
                        pre_build_patch_strip = pre_build_patch_strip,
                        available_deps = project_available_deps,
                        configure_command = project.unstable_configure_command,
                        extra_toolchains = extra_toolchains,
                        extra_env = extra_env,
                        monitor_memory = monitor_memory,
                        resource_set = resource_set,
                    )

                    has_sbuild = True

                post_install_patches = []
                post_install_patch_strip = 0
                extra_deps = []
                extra_data = []
                if pkg_override and not pkg_override.target:
                    post_install_patches = [str(p) for p in pkg_override.post_install_patches]
                    post_install_patch_strip = pkg_override.post_install_patch_strip
                    extra_deps = [str(d) for d in pkg_override.extra_deps]
                    extra_data = [str(d) for d in pkg_override.extra_data]

                whls = {}
                metadata_directory = None
                if not is_no_binary:
                    prev_cfg = install_cfgs.get(k)
                    if prev_cfg:
                        whls.update(prev_cfg.whls)
                        metadata_directory = prev_cfg.metadata_directory
                    for whl in package.get("wheels", []):
                        basename = url_basename(whl["url"])
                        whls[basename] = bdist_table.get(whl["url"])

                        whl_name = parse_whl_name(basename)
                        candidate = "{}-{}.dist-info".format(
                            whl_name.project,
                            whl_name.version.replace("%2B", "+").replace("%2b", "+"),
                        )
                        if metadata_directory != None and candidate != metadata_directory:
                            fail("wheel metadata directory mismatch for {}: {} vs {}".format(
                                k,
                                metadata_directory,
                                candidate,
                            ))
                        metadata_directory = candidate

                install_cfgs[k] = struct(
                    metadata_directory = metadata_directory or "",
                    whls = whls,
                    sbuild = "@{}//:whl".format(sbuild_id) if has_sbuild else None,
                    sbuild_console_scripts = sbuild_console_scripts,
                    post_install_patches = post_install_patches,
                    post_install_patch_strip = post_install_patch_strip,
                    extra_deps = extra_deps,
                    extra_data = extra_data,
                )

            project_cfgs[project_id] = struct(
                dep_to_scc = marked_package_cfg_sccs,
                scc_deps = {
                    k: _merge_scc_dep_markers_by_surface_package(deps)
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
        whl_cfgs = whl_configurations,
        sdist_cfgs = sdist_specs,
        bdist_cfgs = bdist_specs,
    )

def _uv_impl(module_ctx):
    """Module extension entry point.

    Orchestrates dependency resolution: parses hub and project declarations,
    then generates one repository rule per fetched/installed distribution plus a
    `uv_project` rule per project and a `uv_hub` rule per hub. The default sdist
    configure tool is the bundled `detect_native.py` run on a host-platform
    interpreter.

    Args:
        module_ctx: The Bazel module context.
    """

    hub_specs = _parse_hubs(module_ctx)

    cfg = _parse_projects(module_ctx, hub_specs)

    configurations_hub(
        name = "aspect_rules_py_pip_configurations",
        configurations = cfg.whl_cfgs,
    )

    for sdist_name, sdist_cfg in cfg.sdist_cfgs.items():
        if "file" in sdist_cfg:
            sdist_cfg = sdist_cfg["file"]
            http_file(
                name = sdist_name,
                url = sdist_cfg["url"],
                sha256 = _dist_sha256(sdist_cfg),
                downloaded_file_path = url_basename(sdist_cfg["url"]),
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
            sha256 = _dist_sha256(bdist_cfg),
            downloaded_file_path = url_basename(bdist_cfg["url"]),
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
        if sbuild_cfg.extra_toolchains:
            sbuild_kwargs["extra_toolchains"] = sbuild_cfg.extra_toolchains
        if sbuild_cfg.extra_env:
            sbuild_kwargs["extra_env"] = sbuild_cfg.extra_env
        if sbuild_cfg.monitor_memory:
            sbuild_kwargs["monitor_memory"] = True
        if sbuild_cfg.resource_set != "default":
            sbuild_kwargs["resource_set"] = sbuild_cfg.resource_set
        sdist_build(**sbuild_kwargs)

    for install_id, install_cfg in cfg.install_cfgs.items():
        install_kwargs = {
            "metadata_directory": install_cfg.metadata_directory,
            "name": install_id,
            "sbuild": install_cfg.sbuild,
            "sbuild_console_scripts": install_cfg.sbuild_console_scripts,
            "whls": json.encode(install_cfg.whls),
            "whl_files": _deduplicate_whl_files(install_cfg.whls.values()),
        }
        if install_cfg.post_install_patches:
            install_kwargs["post_install_patches"] = json.encode(install_cfg.post_install_patches)
            install_kwargs["post_install_patch_strip"] = install_cfg.post_install_patch_strip
        if install_cfg.extra_deps:
            install_kwargs["extra_deps"] = json.encode(install_cfg.extra_deps)
        if install_cfg.extra_data:
            install_kwargs["extra_data"] = json.encode(install_cfg.extra_data)
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
        "pyproject": attr.label(mandatory = True),
        "lock": attr.label(mandatory = True),
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

_override_package_tag = tag_class(
    attrs = {
        "lock": attr.label(mandatory = True),
        "name": attr.string(mandatory = True),
        "version": attr.string(mandatory = False),
        "target": attr.label(
            mandatory = False,
            doc = "Fully replaces the resolved package with `target`. Mutually exclusive " +
                  "with every modification attribute below.",
        ),
        "console_scripts": attr.string_dict(
            doc = "Complete console scripts for a source-built wheel, mapping script names to module:object entry points.",
        ),
        "monitor_memory": attr.bool(
            default = False,
            doc = "Report approximate Linux process-tree RSS while building this package's wheel.",
        ),
        "resource_set": attr.string(
            default = "default",
            values = resource_set_values,
            doc = "Local execution resources to reserve for this package's wheel build " +
                  "action, from bazel-lib's predefined set ('mem_512m', 'mem_1g', ... " +
                  "'mem_32g', 'cpu_2', 'cpu_4', 'default'). Bazel rounds a memory request " +
                  "up to the named bucket. 'default' reserves nothing extra.",
        ),
        "toolchains": attr.label_list(
            default = [],
            doc = "Extra toolchain targets appended to the generated `pep517_native_whl` " +
                  "call's `toolchains` list. Each target's TemplateVariableInfo make-vars " +
                  "become available for $(VAR) expansion in `env`. These augment the " +
                  "defaults (CC toolchain + CC/CXX/AR/LD/STRIP env); they do not replace them.",
        ),
        "env": attr.string_dict(
            default = {},
            doc = "Extra environment variables merged into the build action's `env` dict. " +
                  "Values may reference $(VAR) make-vars from the default CC toolchain or " +
                  "any extra `toolchains` above.",
        ),
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

Use `target` for full replacement, or the patch/data attributes for surgical
modifications; the two modes are mutually exclusive.

TODO: `srcs_exclude_glob` and `data_exclude_glob` are not yet implemented and
would require either a patch-aware unpack tool or a post-install tree-filtering
action.""",
)

uv = module_extension(
    implementation = _uv_impl,
    tag_classes = {
        "declare_hub": _hub_tag,
        "project": _project_tag,
        "unstable_annotate_packages": _annotations_tag,
        "override_package": _override_package_tag,
    },
)
