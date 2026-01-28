"""
An implementation of fetching dependencies based on consuming UV's lockfiles.

Follows in the footsteps of rules_js's pnpm support by consuming a lockfile
which contains enough information to produce a virtualenv without performing any
dynamic resolution.

Relies on the lockfile to enumerate:
- Source distributions & their digests
- Prebuilt distribitons & their digests
- The dependencies of digests

## Example

    uv = use_repo("@aspect_rules_py//uv:extension.bzl", "uv")
    uv.declare_hub(hub_name = "uv")

    uv.declare_venv(hub_name = "uv", venv_name = "a")
    uv.lockfile(hub_name = "uv", venv_name = "a", lockfile = "third_party/py/venvs/uv-a.lock")

    uv.declare_venv(hub_name = "uv", venv_name = "b")
    uv.lockfile(hub_name = "uv", venv_name = "b", lockfile = "third_party/py/venvs/uv-b.lock")

    use_repo(uv, "uv")

## Features

- Supports cross-platform builds of wheels
- Supports hermetic source builds of wheels
- Automatically handles dependency cycles

## Appendix

[1] https://peps.python.org/pep-0751/
[2] https://peps.python.org/pep-0751/#locking-build-requirements-for-sdists
"""

# Note that platform constraints are specified by markers in the lockfile, they cannot be explicitly specified.

# FIXME: Need to explicitly test a lockfile with platform-conditional deps (tensorflow cpu vs gpu mac/linux)

load("@bazel_features//:features.bzl", features = "bazel_features")
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")
load("//uv/private/constraints:repository.bzl", "configurations_hub")
load("//uv/private/constraints/platform:defs.bzl", "supported_platform")
load("//uv/private/constraints/python:defs.bzl", "supported_python")
load("//uv/private/hub:repository.bzl", "hub_repo")
load("//uv/private/sdist_build:repository.bzl", "sdist_build")
load("//uv/private/tomltool:toml.bzl", "toml")
load("//uv/private/venv_hub:repository.bzl", _venv_hub="venv_hub")
load("//uv/private/whl_install:repository.bzl", "whl_install")
load(":normalize_name.bzl", "normalize_name")
load(":parse_whl_name.bzl", "parse_whl_name")
load(":sccs.bzl", "sccs")
load(":sha1.bzl", "sha1")
load(":pprint.bzl", "pprint")

def _ignored_package(package):
    """
    Indicate whether the package manifest is something we're ignoring.

    This is a workaround for the lockfile package which represents the project itself.

    Args:
        package (dict): A package record from a lockfile

    Returns:
        bool indicating whether the package should be skipped
    """

    # Remote package sources
    # - { source = { registry = "https://some.registry/..." } }
    # - { source = { url = "https://ton.hosting.biz/some.whl" } }
    # FIXME: Git URLs?
    # FIXME: Egg URLs?
    #
    # These seem to be used by the package itself
    # - { source = { editable = "." } }
    # - { source = { virtual = "." } }
    if "virtual" in package["source"] and package["source"]["virtual"] == ".":
        return True

    return False

def _parse_hubs(module_ctx):
    """
    Parse hub declaration tags.

    Produces a hubs table we use to validate venv registrations.

    Args:
        module_ctx (module_ctx): The Bazel module context

    Returns:
        dict; parsed hub specs.
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

def _normalize_deps(lock_id, lock_data):
    """
    Normalize the lockfile.
    1. Compute the "default version" mapping
    2. Update all the dependency statements within the lockfile so they're version disambiguated
    """

    package_versions = {}
    for spec in lock_data.get("package", []):
        # spec: RequirementSpec
        spec["name"] = normalize_name(spec["name"])

        # Collect all the versions first
        package_versions.setdefault(spec["name"], {})[spec["version"]] = 1

    default_versions = {
        requirement: (lock_id, requirement, list(versions.keys())[0], "__base__")
        for requirement, versions in package_versions.items() if len(versions) == 1
    }

    def _fix_version(dep):
        dep["name"] = normalize_name(dep["name"])
        if not "version" in dep:
            # Note that default versions is requirement => (lock_id, name, version, "__base__")
            # So we need to extract the version component here
            dep["version"] = default_versions.get(dep["name"])[2]

    for spec in lock_data.get("package", []):
        for dep in spec.get("dependencies", []):
            _fix_version(dep)
        for extra_deps in spec.get("optional-dependencies", {}).values():
            for dep in extra_deps:
                _fix_version(dep)

    return default_versions, lock_data


def _build_marker_graph(lock_id, lock_data):
    """The graph is {(lock_id, package, version, extra): {(lock_id, package, version, extra): {marker: 1}}}.

    We convert dependencies which no extra list to dependencies on ["__base__"].
    We also ensure that every extra depends on the "__base__" configuration if itself.


    So writing `requests` is understood to be `requests[__base__]`, and
    `requests[foo]` is `requests[__foo__] -> requests[__base__]` which allows is
    to capture the same graph without having do splice in dependencies.

    At this point we also HAVE NOT done extras activation.
    """

    graph = {}
    for spec in lock_data.get("package", []):
        # spec: RequirementSpec
        k = (lock_id, spec["name"], spec["version"], "__base__")
        pkg_deps = graph.setdefault(k, {})
        for dep in spec.get("dependencies", []):
            extras = dep.get("extra", ["__base__"])
            for e in extras:
                pkg_deps.setdefault((lock_id, dep["name"], dep["version"], e), {})[dep.get("marker")] = 1

        for extra_name, optional_deps in spec.get("optional-dependencies", {}).items():
            ek = (lock_id, spec["name"], spec["version"], extra_name)
            # Add a synthetic edge from the extra package to the base package
            pkg_deps = graph.setdefault(ek, {}).setdefault(k, {None: 1})
            for dep in optional_deps:
                extras = dep.get("extra", ["__base__"])
                for e in extras:
                    graph[ek].setdefault((lock_id, dep["name"], dep["version"], e), {})[dep.get("marker")] = 1

    return graph


def _collect_sccs(graph):
    """Given the internal dependency graph, compute strongly connected
    components and the mapping from each dependency to the strongly connected
    component which contains that dependency.

    Returns:
     - A mapping from dependency to scc ID
     - A mapping from scc id to the dependencies which are members of the scc
     - A mapping from scc id to the dependencies which are directs of the scc

    """

    simplified_graph = {dep: nexts.keys() for dep, nexts in graph.items()}
    graph_components = sccs(simplified_graph)

    # Now we need to rebuild markers for intra-scc deps
    scc_graph = {
        sha1(repr(sorted(scc)))[:16]: {m: {} for m in scc}
        for scc in graph_components
    }
    for scc_id, scc in scc_graph.items():
        for start in scc.keys():
            for next in scc.keys():
                next_marks = graph.get(start, {}).get(next, {})
                # Merge the markers back into the next
                if next_marks:
                    scc_graph[scc_id][next].update(next_marks)

        # Ensure that everything has at least the no-op marker
        for next in scc.keys():
            if len(scc_graph[scc_id][next].keys()) == 0:
                scc_graph[scc_id][next].update({None: 1})

    # Compute the mapping from dependency coordinates to the SCC containing that dep
    dep_to_scc = {
        it: scc
        for scc, deps in scc_graph.items()
        for it in deps
    }

    # Compute the mapping from sccs to _direct_ non-member deps for "fattening"
    scc_deps = {}
    for scc, members in scc_graph.items():
        for member in members:
            for dep, markers in graph.get(member, {}).items():
                if dep not in members:
                    scc_deps.setdefault(scc, {}).setdefault(dep, {}).update(markers)

    return dep_to_scc, scc_graph, scc_deps


def _extract_requirement_marker_pairs(req_string, version_map):
    """
    Parses a requirement string into a list of ((name, version, extra), marker) pairs.

    Args:
        req_string: The requirement string (e.g., "foo[bar]>=1.0; sys_platform == 'linux'").
        version_map: A dict mapping package names to default version strings.

    Returns:
        A list of tuples [((name, version, extra), marker), ...].
        The marker is a string or None.
    """
    # 1. Split Requirement and Marker
    # Starlark split() often doesn't support maxsplit, so we use find() + slicing
    semicolon_idx = req_string.find(";")

    marker = None
    if semicolon_idx != -1:
        # Extract and clean the marker
        marker_text = req_string[semicolon_idx + 1:].strip()
        if marker_text:
            marker = marker_text
        # The requirement part is everything before the semicolon
        req_part = req_string[:semicolon_idx].strip()
    else:
        req_part = req_string.strip()

    if not req_part:
        return []

    # 2. Identify end of package name within req_part
    stop_chars = {
        "[": 1,
        "=": 1,
        ">": 1,
        "<": 1,
        "!": 1,
        "~": 1,
        " ": 1
    }

    name_end_idx = len(req_part)

    for i in range(len(req_part)):
        char = req_part[i]
        if char in stop_chars:
            name_end_idx = i
            break

    pkg_name = req_part[:name_end_idx]

    # 3. Extract Extras from req_part
    extras = []

    remainder = req_part[name_end_idx:]

    if remainder.startswith("["):
        close_idx = remainder.find("]")
        if close_idx != -1:
            content = remainder[1:close_idx]
            parts = content.split(",")
            for project_data in parts:
                clean_p = project_data.strip()
                if clean_p:
                    extras.append(clean_p)

    # 4. Look up version
    lock_id, pkg_name, version, _ = version_map.get(pkg_name)

    # 5. Construct results
    # Each result is ((name, ver, extra), marker)
    results = []

    # Base requirement
    base_dep = (lock_id, pkg_name, version, "__base__")
    results.append((base_dep, marker))

    # Extras
    for e in extras:
        dep = (lock_id, pkg_name, version, e)
        results.append((dep, marker))

    return results

def _collect_activated_extras(project_data, default_versions, graph):
    """
    Collect the set of extras which are directly or transitively activated in the given configuration.
    Assumes all marker expressions are live.

    Returns
      - {cfg: 1}
      - {dep: {cfg: {extra_dep: {marker: 1}}}}
    """

    dep_groups = project_data.get("dependency-groups", {
        project_data["project"]["name"]: [
            project_data["project"]["name"],
        ],
    })

    # Normalize dep groups to our dependency triples (graph keys)
    normalized_dep_groups = {}

    # Builds up {package: {configuration: {extra: {marker: 1}}}}
    activated_extras = {}

    for group_name, specs in dep_groups.items():
        normalized_dep_groups[group_name] = []
        for spec in specs:
            for dep, marker in _extract_requirement_marker_pairs(spec, default_versions):
                normalized_dep_groups[group_name].append(dep)

                # Note that this is the base case for the reach set walk below
                # We do this here so it's easy to handle marker expressions
                base = (dep[0], dep[1], dep[2], "__base__")
                activated_extras.setdefault(base, {}).setdefault(group_name, {}).setdefault(dep, {}).update({marker: 1})

    for group_name, deps in normalized_dep_groups.items():
        worklist = list(deps)

        # Worklist graph traversal to handle the reach set
        visited = {}
        idx = 0
        for _ in range(1000000):
            if idx == len(worklist):
                break

            it = worklist[idx]
            visited[it] = 1

            for next, markers in graph.get(it, {}).items():
                # Convert `next`, being a dependency potentially with marker, to its base package
                base = (next[0], next[1], next[2], "__base__")
                # Upsert the base package so that under the appropriate cfg it lists next as a dep with the appropriate markers
                activated_extras.setdefault(base, {}).setdefault(group_name, {}).setdefault(next, {}).update(markers)
                if next not in visited:
                    visited[next] = 1
                    worklist.append(next)

            idx += 1

    return {it: 1 for it in dep_groups.keys()}, activated_extras

def _collate_versions_by_name(activated_extras):
    """
    Transforms the activated extras map into a mapping of names to configs to
    versions to markers. This groups different versions of the same package
    together under the package name.

    Returns:
      {name: {config: {version: {marker: 1}}}}
    """
    result = {}

    for id, configs in activated_extras.items():
        (lock_id, pkg_name, pkg_version, _) = id
        for cfg, deps in configs.items():
            # Ensure path exists: result[name][cfg][version] -> {marker: 1}
            # We use setdefault chain to traverse/create the nested dicts
            version_markers = result.setdefault(pkg_name, {}).setdefault(cfg, {}).setdefault(id, {})

            # deps is {dep_triple: {marker: 1}}
            # We aggregate all markers for this version (from base and extras)
            # into the single map for this version string.
            for markers in deps.values():
                version_markers.update(markers)

    return result

def _collect_markers(graph):
    """
    Return a mapping of marker -> sha1, containing all markers in the graph
    """
    acc = {}
    for _dep, nexts in graph.items():
        for _next, markers in nexts.items():
            for marker in markers.keys():
                # sha1 is "expensive" so we minimize it
                if marker != None and marker not in acc:
                    acc[marker] = sha1(marker)

    return acc

def _collect_configurations(lock):
    wheel_files = {}

    for package in lock.get("package", []):
        for whl in package.get("wheels", []):
            url = whl["url"]
            wheel_name = url.split("/")[-1]  # Find the trailing file name
            wheel_files[wheel_name] = 1

    abi_tags = {}
    platform_tags = {}
    python_tags = {}

    # Platform definitions from groups of configs
    configurations = {}

    for wheel_name in wheel_files.keys():
        parsed_wheel = parse_whl_name(wheel_name)
        for python_tag in parsed_wheel.python_tags:
            # Ignore configurations for unsupported interpreters
            if not supported_python(python_tag):
                continue

            python_tags[python_tag] = 1

            for platform_tag in parsed_wheel.platform_tags:
                # Ignore configurations for unsupported platforms
                if not supported_platform(platform_tag):
                    continue

                platform_tags[platform_tag] = 1

                for abi_tag in parsed_wheel.abi_tags:
                    abi_tags[abi_tag] = 1

                    # Note that we are NOT filtering out
                    # impossible/unsatisfiable python+abi tag possibilities.
                    # It's not aesthetic but it is simple enough.
                    configuration = "{}-{}-{}".format(python_tag, platform_tag, abi_tag)

                    configurations[configuration] = [
                        "@aspect_rules_py//uv/private/constraints/platform:{}".format(platform_tag),
                        "@aspect_rules_py//uv/private/constraints/abi:{}".format(abi_tag),
                        "@aspect_rules_py//uv/private/constraints/python:{}".format(python_tag),
                    ]

    return configurations

def _collect_bdists(lock_data):
    bdist_specs = {}
    bdist_table = {}
    for package in lock_data.get("package", []):
        for bdist in package.get("wheels", []):
            bdist_repo_name = "whl__{}__{}".format(package["name"], bdist["hash"].split(":")[1][:16])
            bdist_specs[bdist_repo_name] = bdist
            bdist_table[bdist["hash"]] = "@{}//:file".format(bdist_repo_name)

    return bdist_specs, bdist_table

def _collect_sdists(lock_data):
    sdist_specs = {}
    sdist_table = {}
    for package in lock_data.get("package", []):
        if "sdist" in package:
            sdist = package["sdist"]
            sdist_repo_name = "sdist__{}__{}".format(package["name"], sdist["hash"].split(":")[1][:16])
            sdist_specs[sdist_repo_name] = sdist
            sdist_table[sdist["hash"]] = "@{}//:file".format(sdist_repo_name)

    return sdist_specs, sdist_table

def _parse_projects(module_ctx, hub_specs):
    """
    Parse project declaration tags.

    Returns:
        {lock_id: struct(lock, dep_to_scc, scc_graph, scc_deps)}
        {hub: {nominal_requirement: {cfg: lock_qualified_}}
    """

    lock_cfgs = {}
    hub_cfgs = {}
    marker_specs = {}
    whl_configurations = {}
    sdist_specs = {}
    sdist_table = {}
    bdist_specs = {}
    bdist_table = {}
    install_cfgs = {}
    install_table = {}

    # Collect all hubs, ensure we have no dupes
    for mod in module_ctx.modules:
        for project in mod.tags.project:
            project_data = toml.decode_file(module_ctx, project.pyproject)
            lock_data = toml.decode_file(module_ctx, project.lock)

            # This SHOULD be stable enough.
            # We'll rebuild the lock hub whenever the toml changes.
            # Reusing the name is fine.
            lock_id = sha1(repr(project.lock))[:16]

            # Read these from the project or honor the module state
            project_name = project.name or project_data["project"]["name"]
            # FIXME: Error if this wasn't provided and the version is marked as dynamic
            project_version = project.version or project_data["project"]["version"]

            if project.hub_name not in hub_specs:
                fail("Project {} in {} refers to hub {} which is not configured for that module. Please declare it.".format(project_name, mod.name, project.hub_name))

            if lock_id not in lock_cfgs:
                default_versions, lock_data = _normalize_deps(lock_id, lock_data)

                marker_graph = _build_marker_graph(lock_id, lock_data)
                marker_specs.update(_collect_markers(marker_graph))

                bd, bt = _collect_bdists(lock_data)
                bdist_specs.update(bd)
                bdist_table.update(bt)

                sd, st = _collect_sdists(lock_data)
                sdist_specs.update(sd)
                sdist_table.update(st)

                whl_configurations.update(_collect_configurations(lock_data))

                dep_to_scc, scc_graph, scc_deps = _collect_sccs(marker_graph)

                for package in lock_data.get("package", []):
                    k = "whl_install__{}__{}__{}".format(lock_id, package["name"], package["version"])
                    install_table[(lock_id, package["name"], package["version"], "__base__")] = "@{}//:install".format(k)

                    sdist = package.get("sdist")
                    if sdist:
                        sdist = sdist_table.get(sdist["hash"])

                    install_cfgs[k] = struct(
                        whls = {whl["url"].split("/")[-1].split("?")[0].split("#")[0]: bdist_table.get(whl["hash"]) for whl in package.get("wheels", [])},
                        sdist = sdist,
                    )

                # Rebuild the SCC graph to point to member installs
                scc_graph = {
                    scc_id: {install_table[m]: markers for m, markers in members.items()}
                    for scc_id, members in scc_graph.items()
                }

                lock_cfgs[lock_id] = struct(
                    default_versions = default_versions,
                    dep_to_scc = dep_to_scc,
                    scc_graph = scc_graph,
                    scc_deps = scc_deps,
                )

            else:
                cfg = lock_cfgs[lock_id]
                default_versions = cfg.default_versions
                dep_to_scc = cfg.dep_to_scc
                scc_graph = cfg.scc_graph
                scc_deps = cfg.scc_deps

            configuration_names, activated_extras = _collect_activated_extras(project_data, default_versions, marker_graph)
            version_activations = _collate_versions_by_name(activated_extras)

            hub_cfg = hub_cfgs.setdefault(project.hub_name, struct(
                configurations = {},
                version_activations = {},
                extra_activations = {},
            ))
            for cfg in configuration_names.keys():
                if cfg in hub_cfg.configurations:
                    fail("Conflict on configuration name {} in hub {}".format(cfg, project.hub_name))

            hub_cfg.configurations.update(configuration_names)
            hub_cfg.version_activations.update(version_activations)
            hub_cfg.extra_activations.update(activated_extras)

    return struct(
        lock_cfgs = lock_cfgs,
        hub_cfgs = hub_cfgs,
        install_cfgs = install_cfgs,
        marker_specs = marker_specs,
        whl_configurations = whl_configurations,
        sdist_specs = sdist_specs,
        bdist_specs = bdist_specs,
    )


def _config_marker(marker_registry, expr):
    return "@aspect_rules_py_pip_configurations//:{}".format(marker_registry[expr])

def venv_hub(name, cfg, sdist_table, bdist_table, marker_table):
    """
    Psuedo-repo-rule.

    Take a single hub configuration and generate all the components.
    """

    # print(name, pprint(cfg))

    def _name(k):
        if k[2] == "__base__":
            return "{}__{}".format(k[0], k[1])
        else:
            return "{}__{}__extra__{}".format(*k)

    # We have to re-key the extra activations, graph and package configs so that we're using a json-friendly key
    activated_extras = {
        _name(k): {_name(ek): markers}
        for k, extras in cfg.activated_extras.items()
        for ek, markers in extras.items()
    }
    graph = {
        _name(k): {_name(d): markers}
        for k, deps in cfg.graph.items()
        for d, markers in deps.items()
    }
    pkg_cfgs = {
        _name(pkg): pkg_cfg
        for pkg, pkg_cfg in cfg.package_cfgs.items()
    }

    print(pprint(activated_extras))
    print(pprint(graph))
    print(pprint(pkg_cfgs))


def _uv_impl(module_ctx):
    """
    And now for the easy bit.

    - Collect hub configurations
    - Collect venv configurations per hub
    - Collect and parse lockfiles per venv per hub
    - Collect annotations and overrides per venv and hub
    - Generate sdist fetches for every locked package
    - Generate sdist to whl builds for every locked package
    - Generate whl fetches for every locked package
    - Generate an install choosing between a sdist build and a prebuilt whl for every package
    - For each venv generate a hub over the installs of packages in that venv
    - For each hub generate a hub fanning out to the venvs which make up the hub

    Note that we also generate a config repo which is used to introspect the
    host platform and establish flag default values so the default configuration
    is appropriate for the host platform.

    """

    hub_specs = _parse_hubs(module_ctx)

    cfg = _parse_projects(module_ctx, hub_specs)

    configurations_hub(
        name = "aspect_rules_py_pip_configurations",
        configurations = cfg.whl_configurations,
        markers = cfg.marker_specs,
    )

    print(pprint(cfg))

    for sdist_name, sdist_cfg in cfg.sdist_specs.items():
        http_file(
            name = sdist_name,
            url = sdist_cfg["url"],
            sha256 = sdist_cfg["hash"][len("sha256:"):],
            downloaded_file_path = sdist_cfg["url"].split("/")[-1].split("?")[0].split("#")[0],
        )

    for bdist_name, bdist_cfg in cfg.bdist_specs.items():
        http_file(
            name = bdist_name,
            url = bdist_cfg["url"],
            sha256 = bdist_cfg["hash"][len("sha256:"):],
            downloaded_file_path = bdist_cfg["url"].split("/")[-1].split("?")[0].split("#")[0],
        )

    for hub_name, hub_cfg in cfg.hub_specs.items():
        for cfg_name, cfg_spec in hub_cfg.items():
            venv_hub(
                name = cfg_name,
                cfg = cfg_spec,
                sdist_table = cfg.sdist_table,
                bdist_table = cfg.bdist_table,
                marker_table = cfg.marker_specs,
            )

        # hub(
        #     name = hub_name,
        #     cfg = hub_cfg,
        # )

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
    },
)

_annotations_tag = tag_class(
    attrs = {
        "hub_name": attr.string(mandatory = True),
        "venv_name": attr.string(mandatory = True),
        "src": attr.label(mandatory = True),
    },
)

_declare_entrypoint = tag_class(
    attrs = {
        "requirement": attr.string(mandatory = True),
        "name": attr.string(mandatory = True),
        "entrypoint": attr.string(mandatory = True),
    },
)

_override_requirement = tag_class(
    attrs = {
        "hub_name": attr.string(mandatory = True),
        "configuration": attr.string(mandatory = True),
        "requirement": attr.string(mandatory = True),
        "target": attr.label(mandatory = True),
    },
)

# TODO: patch_requirement

uv = module_extension(
    implementation = _uv_impl,
    tag_classes = {
        "declare_hub": _hub_tag,
        "project": _project_tag,
        "unstable_annotate_requirements": _annotations_tag,
        "override_requirement": _override_requirement,
        "declare_entrypoint": _declare_entrypoint,
    },
)
