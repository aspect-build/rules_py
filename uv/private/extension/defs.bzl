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
uv.declare_hub(hub_name = "uv")
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
    """The distribution's sha256 for http_file, or None for other hash algorithms."""
    hash = dist.get("hash", "")
    return hash[len("sha256:"):] if hash.startswith("sha256:") else None

def _deduplicate_whl_files(whls):
    """Returns unique non-empty wheel labels while preserving order."""
    whl_files = []
    seen = {}
    for whl in whls:
        if not whl or whl in seen:
            continue
        seen[whl] = True
        whl_files.append(whl)
    return whl_files

def parse_declared_console_script(name, entry_point):
    """Canonicalize one override_package console-script declaration.

    Args:
        name: Script name installed under the venv's bin directory.
        entry_point: Python entry point encoded as module:object.

    Returns:
        The canonical name=module:object string, or None when invalid.
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
    """Merge SCC dep markers, re-keyed from lock tuple to surface package name.

    SCC external deps are keyed by the fully versioned lock tuple, but the
    generated hub targets key on the surface package alias. Merging across all
    versions lets split dependencies (e.g. chdb -> pyarrow) preserve their full
    platform coverage instead of overwriting each other.
    """
    merged = {}
    for dep, markers in marked_deps.items():
        merged.setdefault(dep[1], {}).update(markers)
    return merged

def _parse_hubs(module_ctx):
    """Collect the set of hub names declared across all modules.

    The result is used only to validate that each `uv.project()` refers to a
    declared hub. Uniqueness across repositories is deliberately NOT enforced:
    the conventional `@pypi` hub may be referenced by many modules, since build
    configuration is disambiguated on the venv, not the hub.

    Args:
        module_ctx: The Bazel module context.

    Returns:
        A dict whose keys are declared hub names (values are unused).
    """
    hub_specs = {}

    for mod in module_ctx.modules:
        for hub in mod.tags.declare_hub:
            hub_specs[hub.hub_name] = True

    return hub_specs

def _parse_projects(module_ctx, hub_specs):
    """Resolve every `uv.project()` declaration into repository-rule inputs.

    For each project the `pyproject.toml` and `uv.lock` are decoded, the
    dependency graph and its strongly connected components are computed, and the
    per-package install/build/override configuration is assembled.

    Args:
        module_ctx: The Bazel module context.
        hub_specs: Hub names known to be declared, as returned by `_parse_hubs`;
            used to reject projects that reference an undeclared hub.

    Returns:
        A struct of the inputs consumed by `_uv_impl`, with fields:

          - project_cfgs: `{project_id -> {dep_to_scc, scc_deps, scc_graph}}`
            graph data, JSON-encoded downstream.
          - hub_cfgs: `{hub_name -> {configurations, packages}}` aggregated
            per-hub configuration/package surface.
          - install_cfgs: `{whl_install key -> install struct}` wiring each
            resolved package to its wheels, optional sbuild and patches.
          - sbuild_cfgs: `{sbuild_id -> sdist_build struct}` for packages that
            may build a wheel from source.
          - whl_cfgs: platform configuration matrix for `configurations_hub`.
          - sdist_cfgs / bdist_cfgs: `{name -> fetch spec}` for `http_file` /
            `git_archive` downloads.
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

    # FIXME: Collect build deps files/annotations
    for mod in module_ctx.modules:
        project_locks = {project.lock: True for project in mod.tags.project}
        for override in mod.tags.override_package:
            if override.lock == None and override.target != None:
                fail("uv.override_package() for '{}': `target` requires `lock`.".format(override.name))
            if override.lock != None and override.lock not in project_locks:
                fail("uv.override_package() for '{}' refers to lock '{}', but module '{}' has no uv.project() for that lock.".format(
                    override.name,
                    override.lock,
                    mod.name,
                ))

            if override.pre_build_patch_strip and not override.pre_build_patches:
                fail("uv.override_package() for '{}': `pre_build_patch_strip` requires `pre_build_patches`.".format(override.name))
            if override.post_install_patch_strip and not override.post_install_patches:
                fail("uv.override_package() for '{}': `post_install_patch_strip` requires `post_install_patches`.".format(override.name))

            has_target = override.target != None
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

        unscoped_matches = {i: 0 for i, override in enumerate(mod.tags.override_package) if override.lock == None}

        for project in mod.tags.project:
            project_data = toml.decode_file(module_ctx, project.pyproject)
            tool_uv = project_data.get("tool", {}).get("uv", {})
            lock_data = toml.decode_file(module_ctx, project.lock)

            # The stamp derives from the project name: stable across reloads and
            # unique within a hub. Repository keys are rebuilt whenever the toml
            # changes, so a human-readable stamp is safe to reuse.
            project_stamp = normalize_name(project_data["project"]["name"])
            project_id = "project__" + project_stamp

            project_name = project.name or project_data["project"]["name"]

            if project.hub_name not in hub_specs:
                fail("Project {} in {} refers to hub {} which is not configured for that module. Please declare it.".format(project_name, mod.name, project.hub_name))

            no_binary_packages = {
                normalize_name(p): True
                for p in tool_uv.get("no-binary-package", [])
            }

            default_versions, package_versions, lock_data = normalize_deps(project_id, lock_data)

            locked_urls = {}
            for locked_package in lock_data.get("package", []):
                dependency = (project_id, locked_package["name"], locked_package["version"], "__base__")
                artifacts = locked_package.get("wheels", []) + [
                    locked_package.get("sdist", {}),
                    locked_package.get("source", {}),
                ]
                for artifact in artifacts:
                    url = artifact.get("url")
                    if url:
                        locked_urls[(locked_package["name"], url)] = dependency

            def _resolve(name, version):
                name = normalize_name(name)
                if version:
                    return (project_id, name, version, "__base__")
                elif name in default_versions:
                    return default_versions[name]
                return None

            lock_build_dep_anns = {}
            lock_conditional_build_dep_anns = {}
            lock_native_anns = {}
            extra_build_dependencies = tool_uv.get("extra-build-dependencies", {})
            for package, extra_deps in extra_build_dependencies.items():
                package_name = normalize_name(package)
                targets = [
                    (project_id, package_name, version, "__base__")
                    for version in package_versions.get(package_name, {})
                ]
                if not targets:
                    # Allow a shared annotation file to include entries for other locks.
                    continue
                deps = []
                conditional_deps = {}
                for dep in extra_deps:
                    # TODO(konsti): We currently ignore match-runtime. Since we're already
                    # using locked dependencies for building, this works as long as there is
                    # only a single version of the package.
                    if type(dep) == "dict":
                        dep = dep["requirement"]
                    resolved_deps = extract_requirement_marker_pairs(
                        project.lock,
                        project_id,
                        dep,
                        {},
                        package_versions,
                        locked_urls = locked_urls,
                        fail_if_missing = False,
                    )
                    if not resolved_deps:
                        fail((
                            "Unable to resolve extra build dependency `{}` for package {} in {}. " +
                            "`uv.lock` does not include packages referenced only by " +
                            "`tool.uv.extra-build-dependencies`. Add the dependency as a dependency " +
                            "and regenerate the lock."
                        ).format(repr(dep), repr(package), project.pyproject))
                    for resolved, marker in resolved_deps:
                        if marker:
                            conditional_deps.setdefault(marker, []).append(resolved)
                        else:
                            deps.append(resolved)
                for target in targets:
                    lock_build_dep_anns[target] = deps
                    lock_conditional_build_dep_anns[target] = conditional_deps

            for ann in mod.tags.unstable_annotate_packages:
                if ann.lock == project.lock:
                    annotations = toml.decode_file(module_ctx, ann.src)
                    for package in annotations.get("package", []):
                        target = _resolve(package["name"], package.get("version"))
                        if target == None:
                            # Allow a shared annotation file to include entries for other locks.
                            continue
                        if "native" in package:
                            if type(package["native"]) != "bool":
                                fail("Annotation `native` for package {} in {} must be a boolean, got {}".format(package["name"], ann.src, repr(package["native"])))
                            lock_native_anns[target] = package["native"]
                        if "build-dependencies" in package:
                            deps = []
                            skip = False
                            for dep in package["build-dependencies"]:
                                resolved = _resolve(dep["name"], dep.get("version"))
                                if resolved == None:
                                    skip = True
                                    break
                                deps.append(resolved)
                            if not skip:
                                # Legacy and uv-native annotations compose, including
                                # any marker-qualified uv-native dependencies.
                                lock_build_dep_anns[target] = lock_build_dep_anns.get(target, []) + deps

            package_overrides = {}
            package_console_scripts = {}
            for i, override in enumerate(mod.tags.override_package):
                if override.lock != None and override.lock != project.lock:
                    continue

                name = normalize_name(override.name)
                available_versions = package_versions.get(name, {})
                if override.lock == None and not available_versions:
                    continue

                v = override.version or default_versions.get(name, (None, None, None, None))[2]
                if not v:
                    fail("Overridden project {} neither specifies a version nor has an implied singular version in lock {}!".format(override.name, project.lock))
                if v not in available_versions:
                    if override.lock == None:
                        continue
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

                if override.lock == None:
                    unscoped_matches[i] += 1

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

            # SCC graph shapes:
            #   scc_graph:        {scc_id -> {member -> markers}}
            #   scc_deps:         {scc_id -> {dep -> markers}}
            #   package_cfg_sccs: {package -> {cfg -> scc_id}}
            scc_graph = {}
            scc_deps = {}
            package_cfg_sccs = {}

            # Shared across configurations so SCCs with identical content share
            # one id; content differing only in deps/markers stays distinct.
            scc_id_state = {}
            for cfg in configuration_names:
                cfgd_marker_graph = activate_extras(marker_graph, activated_extras, cfg)
                cfgd_dep_to_scc, cfgd_scc_graph, cfgd_scc_deps = collect_sccs(cfgd_marker_graph, scc_id_state)

                # Aggregated across configurations; markers that vary per graph
                # are intentionally flattened here.
                scc_graph.update(cfgd_scc_graph)
                scc_deps.update(cfgd_scc_deps)

                for package, scc in cfgd_dep_to_scc.items():
                    package_cfg_sccs.setdefault(package, {})[cfg] = scc

            marked_package_cfg_sccs = {}
            for package, cfgs in version_activations.items():
                for cfg, versions in cfgs.items():
                    for version, markers in versions.items():
                        marked_package_cfg_sccs.setdefault(package, {}).setdefault(cfg, {}).setdefault(package_cfg_sccs[version][cfg], {}).update(markers)

            # The lock may contain inactive dev-only packages. Keep the SCCs
            # reachable from emitted aliases so they cannot leak into Gazelle.
            reachable_sccs = {
                scc_id: True
                for cfgs in marked_package_cfg_sccs.values()
                for sccs in cfgs.values()
                for scc_id in sccs
            }
            missing_sccs = [scc_id for scc_id in reachable_sccs if scc_id not in scc_graph]
            if missing_sccs:
                fail("Surface package aliases reference missing SCCs: {}".format(missing_sccs))

            scc_graph = {scc_id: members for scc_id, members in scc_graph.items() if scc_id in reachable_sccs}
            scc_deps = {scc_id: deps for scc_id, deps in scc_deps.items() if scc_id in reachable_sccs}
            for scc_id, deps in scc_deps.items():
                for dep in deps:
                    if dep[1] not in marked_package_cfg_sccs:
                        fail("SCC {} depends on package {} without a surface alias".format(scc_id, dep[1]))

            # Pre-build the per-project available_deps mapping from the
            # lockfile. This gives each sdist configure tool visibility
            # into the packages within this project's dependency perimeter.
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
                    # Already populated by a uv.override_package(target=...); skip.
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

                # WARNING: Loop invariant; this flag needs to be False by
                # default and set if we do a build.
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
                    # HACK: Note that we resolve these LAZILY so that
                    # bdist-only or fully overridden configurations don't
                    # have to provide the build tools.

                    # FIXME: We can read the [build-system] requires=
                    # property if it exists for the sdist. Question is how
                    # to defer choosing deps until the repo rule when we
                    # could do pyproject.toml introspection.
                    ann_key = (project_id, normalize_name(package["name"]), package["version"], "__base__")
                    build_deps = lock_build_dep_anns.get(ann_key) or []
                    conditional_build_deps = lock_conditional_build_dep_anns.get(ann_key) or {}
                    is_native = "auto"
                    if ann_key in lock_native_anns:
                        is_native = "true" if lock_native_anns[ann_key] else "false"
                    if lock_build_deps == None:
                        # For optional sdist fallbacks (sdist present but a
                        # wheel will be picked at install time), tolerate a
                        # lock that doesn't carry `default_build_dependencies`
                        # — the sbuild target is never selected, so demanding
                        # the build tools would force every project to pin
                        # them. Fail eagerly when sbuild is guaranteed to be
                        # selected: forced builds (`no-binary-package`) or
                        # sdist-only packages (no wheels in the lock). Other
                        # platform-mismatch cases can't be detected here
                        # because we don't know the target build platform.
                        sbuild_required = is_no_binary or not package.get("wheels", [])
                        lock_build_deps = [
                            it[0]
                            for req in project.default_build_dependencies
                            for it in extract_requirement_marker_pairs(
                                project.lock,
                                project_id,
                                req,
                                default_versions,
                                package_versions,
                                locked_urls,
                                fail_if_missing = sbuild_required,
                            )
                        ]

                    build_deps = sets.to_list(sets.make(build_deps + lock_build_deps))
                    conditional_build_deps = {
                        marker: sets.to_list(sets.make([
                            dep
                            for dep in deps
                            if dep not in build_deps
                        ]))
                        for marker, deps in conditional_build_deps.items()
                    }
                    sbuild_conditional_deps = {}
                    for marker, deps in conditional_build_deps.items():
                        for dep in deps:
                            label = "@{0}//:{1}".format(*dep)
                            previous = sbuild_conditional_deps.get(label)
                            if previous:
                                sbuild_conditional_deps[label] = "({}) or ({})".format(previous, marker)
                            else:
                                sbuild_conditional_deps[label] = marker

                    pre_build_patches = []
                    pre_build_patch_strip = 0
                    if pkg_override and pkg_override.pre_build_patches:
                        pre_build_patches = [str(p) for p in pkg_override.pre_build_patches]
                        pre_build_patch_strip = pkg_override.pre_build_patch_strip

                    # `toolchains` / `env` on `uv.override_package` augment
                    # the defaults baked into sdist_build's BUILD template —
                    # they don't replace them. Empty == no augmentation.
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
                        # A base requirement and its extras resolve through the same
                        # project package label, so deduplicate after rendering labels.
                        deps = sets.to_list(sets.make([
                            "@{0}//:{1}".format(*it)
                            for it in build_deps
                        ])),
                        conditional_deps = sbuild_conditional_deps,
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

                # uv can emit multiple lock records for the same package/version
                # (e.g. resolution-marker forks), each carrying a different
                # subset of wheels. Merge with any previously translated record
                # for the same install instead of overwriting (and thus
                # dropping) it.
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

                        # Every wheel of a package/version installs the same
                        # `<project>-<version>.dist-info` directory, so the
                        # repo rule only needs one name to `extract` the
                        # metadata regardless of which platform wheel is
                        # selected. A divergence means our derivation is wrong.
                        #
                        # Derive both halves from the wheel filename: it and
                        # the dist-info dir share the build backend's escaping,
                        # and URL-encoded `+` is literal in the archive member.
                        # The build tag (absent from dist-info) is dropped.
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

            # These structures are re-keyed into JSON-serializable shapes for the
            # repo-rule boundary. Structured keys are preserved verbatim and
            # re-parsed on the other side; mangling happens there as needed.
            #
            # FIXME: extract a re-keying helper.
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

            hub_cfg.configurations.update({
                name: project_id
                for name in configuration_names.keys()
            })

            # Build a {requirement: {cfg: target mapping}}
            for package, cfgs in version_activations.items():
                for cfg in cfgs.keys():
                    hub_cfg.packages.setdefault(package, {})[cfg] = "@{}//:{}".format(project_id, package)

        for i, override in enumerate(mod.tags.override_package):
            if override.lock == None and not unscoped_matches[i]:
                if override.version:
                    fail("uv.override_package() for '{}=={}' matches no uv.project() locks in module '{}'.".format(override.name, override.version, mod.name))
                fail("uv.override_package() for '{}' matches no uv.project() locks in module '{}'.".format(override.name, mod.name))

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
    """The implementation function for the `uv` module extension.

    This function is the main entry point for the module extension. It orchestrates
    the entire dependency resolution process, which includes:
    - Parsing `uv.declare_hub()` and `uv.project()` declarations.
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

    # Resolve the sdist configure tool. The default is our bundled
    # detect_native.py, run with a PBS interpreter for the host platform.
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
            sbuild_kwargs["available_deps"] = sbuild_cfg.available_deps
        if sbuild_cfg.conditional_deps:
            sbuild_kwargs["conditional_deps"] = sbuild_cfg.conditional_deps
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
            # Parallel list of the same wheel labels as a real label_list,
            # so the whl_install repo rule can `rctx.path()` them to peek
            # at `*.dist-info/RECORD` for top-level metadata.
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

    return module_ctx.extension_metadata(reproducible = True)

_hub_tag = tag_class(
    attrs = {
        "hub_name": attr.string(mandatory = True),
    },
    doc = """Declare a named hub: a shared dependency namespace that `uv.project()` registrations bind to.""",
)

_project_tag = tag_class(
    attrs = {
        "hub_name": attr.string(
            mandatory = True,
            doc = "Name of a hub previously declared with `uv.declare_hub`.",
        ),
        "name": attr.string(
            mandatory = False,
            doc = "Override the project name; defaults to `[project].name` in `pyproject.toml`.",
        ),
        "version": attr.string(
            mandatory = False,
            doc = "Override the project version; defaults to `[project].version` in `pyproject.toml`.",
        ),
        "pyproject": attr.label(
            mandatory = True,
            doc = "The `pyproject.toml` describing this project.",
        ),
        "lock": attr.label(
            mandatory = True,
            doc = "The `uv.lock` pinning this project's dependency graph.",
        ),
        "default_build_dependencies": attr.string_list(
            mandatory = False,
            default = [
                "build",
            ],
            doc = "Requirement names resolved from the lock and injected as build tools " +
                  "for sdists that build a wheel. Only demanded when an sbuild is " +
                  "guaranteed to be selected (forced builds or sdist-only packages).",
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
    doc = """Register a `pyproject.toml` + `uv.lock` pair into a hub, resolving the project's locked dependency graph.""",
)

_annotations_tag = tag_class(
    attrs = {
        "lock": attr.label(
            mandatory = True,
            doc = "The `uv.lock` these annotations apply to.",
        ),
        "src": attr.label(
            mandatory = True,
            doc = "TOML file of per-package annotations (`[package]` tables carrying `native` and/or `build-dependencies`).",
        ),
    },
    doc = """Attach per-package build annotations (native flag, extra build-dependencies) from a TOML file to a specific lock.""",
)

_override_package_tag = tag_class(
    attrs = {
        "lock": attr.label(
            mandatory = False,
            doc = "The `uv.lock` this override applies to. Omit it to apply modifications across every `uv.project()` declared by the same module.",
        ),
        "name": attr.string(mandatory = True),
        "version": attr.string(mandatory = False),
        "target": attr.label(
            mandatory = False,
            doc = "Full replacement: a target that substitutes for the package entirely. " +
                  "Mutually exclusive with all patch/data modification attributes.",
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
            doc = "Local execution resources to reserve for this package's wheel build action. " +
                  "One of bazel-lib's predefined resource sets ('mem_512m', 'mem_1g', … 'mem_32g', " +
                  "'cpu_2', 'cpu_4', 'default'). Bazel rounds a memory request up to the named " +
                  "bucket.",
        ),
        "toolchains": attr.label_list(
            default = [],
            doc = "Extra toolchain targets forwarded to the generated pep517_native_whl(...) call's `toolchains` list. Each target's TemplateVariableInfo make-variables become available for $(VAR) expansion in `env`.",
        ),
        "env": attr.string_dict(
            default = {},
            doc = "Extra environment variables merged into the build action's `env` dict. Values may reference $(VAR) make-variables sourced from extra `toolchains` listed above. Prefix an execroot-relative path with `$(EXECROOT)/` so it remains valid after the backend changes into the unpacked source tree. Omit CC/CXX/AR/LD/STRIP to use the configured C++ action tools.",
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

        # FIXME: srcs_exclude_glob and data_exclude_glob are not yet implemented.
        # Implementing them requires either extending the Rust unpack tool to
        # accept exclusion patterns at install time, or adding a post-install
        # tree-filtering action that can selectively remove files from a tree
        # artifact. The attrs are commented out to avoid exposing a non-functional
        # API surface.
        #
        # "srcs_exclude_glob": attr.string_list(
        #     default = [],
        #     doc = "Glob patterns to exclude from the package's srcs (e.g. '**/tests/**').",
        # ),
        # "data_exclude_glob": attr.string_list(
        #     default = [],
        #     doc = "Glob patterns to exclude from the package's data.",
        # ),
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

Use `target` for full replacement, or use the patch/data attributes
for surgical modifications. Omitting `lock` applies modifications across all
project locks declared by the same module. Specifying `target` requires `lock`
and is mutually exclusive with all other modification attributes.""",
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
