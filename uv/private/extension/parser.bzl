"Functions for parsing `uv.project()` declarations."

load("//uv/private:parse_whl_name.bzl", "parse_whl_name")
load("//uv/private:sha1.bzl", "sha1")
load("//uv/private/constraints/platform:defs.bzl", "supported_platform")
load("//uv/private/constraints/python:defs.bzl", "supported_python")
load("//uv/private/graph:sccs.bzl", "sccs")
load("//uv/private/pprint:defs.bzl", "pprint")
load("//uv/private/tomltool:toml.bzl", "toml")
load(":normalize_name.bzl", "normalize_name")

def _normalize_deps(lock_id, lock_data):
    """Normalizes dependency specifications in a lockfile.

    This function performs two main normalization steps:
    1.  It computes a "default version" for each package, which is used when a
        dependency specification does not include a version. The default version
        is only computed for packages that have a single version in the lockfile.
    2.  It updates all dependency statements within the lockfile to be
        version-disambiguated, using the default versions where necessary.

    Args:
        lock_id: A unique identifier for the lockfile.
        lock_data: The parsed content of the `uv.lock` file.

    Returns:
        A tuple containing:
        - A dictionary mapping package names to their default version dependency
          tuples `(lock_id, package_name, version, "__base__")`.
        - The normalized `lock_data` dictionary.
    """

    package_versions = {}
    for spec in lock_data.get("package", []):
        # spec: RequirementSpec
        spec["name"] = normalize_name(spec["name"])

        # Collect all the versions first
        package_versions.setdefault(spec["name"], {})[spec["version"]] = 1

    default_versions = {
        requirement: (lock_id, requirement, list(versions.keys())[0], "__base__")
        for requirement, versions in package_versions.items()
        if len(versions) == 1
    }

    def _fix_version(dep):
        dep["name"] = normalize_name(dep["name"])
        if not "version" in dep:
            # Note that default versions is requirement => (lock_id, name, version, "__base__")
            # So we need to extract the version component here
            dep["version"] = default_versions.get(dep["name"])[2]

    for spec in lock_data.get("package", []):
        # Backfill the sdist URL if the source is a URL file
        if "sdist" in spec and not "url" in spec["sdist"]:
            spec["sdist"]["url"] = spec["source"]["url"]

        for dep in spec.get("dependencies", []):
            _fix_version(dep)

        for extra_deps in spec.get("optional-dependencies", {}).values():
            for dep in extra_deps:
                _fix_version(dep)

    return default_versions, lock_data

def _build_marker_graph(lock_id, lock_data):
    """Builds a dependency graph from a lockfile.

    The graph is represented as a dictionary where the keys are `Dependency`
    tuples `(lock_id, package, version, extra)` and the values are dictionaries
    of their dependencies. The dependency dictionaries are keyed by `Dependency`
    tuples and their values are dictionaries of markers.

    This function also normalizes dependencies on extras. Dependencies without an
    extra are converted to a dependency on the `__base__` extra. Each extra also
    gets a synthetic dependency on the `__base__` package of the same version.

    Args:
        lock_id: A unique identifier for the lockfile.
        lock_data: The parsed content of the `uv.lock` file.

    Returns:
        A dictionary representing the dependency graph.
    """

    graph = {}
    for spec in lock_data.get("package", []):
        # spec: RequirementSpec
        k = (lock_id, spec["name"], spec["version"], "__base__")
        graph.setdefault(k, {})
        for dep in spec.get("dependencies", []):
            extras = dep.get("extra", ["__base__"])
            for e in extras:
                ek = (lock_id, dep["name"], dep["version"], e)
                graph[k].setdefault(ek, {})
                graph[k][ek][dep.get("marker", "")] = 1

        for extra_name, optional_deps in spec.get("optional-dependencies", {}).items():
            ek = (lock_id, spec["name"], spec["version"], extra_name)

            # Add a synthetic edge from the extra package to the base package
            graph.setdefault(ek, {k: {"": 1}})
            for dep in optional_deps:
                extras = dep.get("extra", ["__base__"])
                for e in extras:
                    eek = (lock_id, dep["name"], dep["version"], e)
                    graph[ek].setdefault(eek, {})
                    graph[ek][eek][dep.get("marker", "")] = 1

    return graph

def _collect_sccs(graph):
    """Computes Strongly Connected Components (SCCs) for a dependency graph.

    This function takes a dependency graph and identifies all the SCCs, which
    are groups of packages that have cyclic dependencies on each other.

    Args:
        graph: The dependency graph, as returned by `_build_marker_graph`.

    Returns:
        A tuple containing:
        - A dictionary mapping each dependency to the ID of the SCC that
          contains it.
        - A dictionary representing the graph of SCCs, where the keys are SCC IDs
          and the values are dictionaries of member dependencies and their
          markers.
        - A dictionary mapping each SCC ID to its direct, non-member
          dependencies.
    """

    simplified_graph = {pkg: deps.keys() for pkg, deps in graph.items()}
    graph_components = sccs(simplified_graph)

    # Now we need to rebuild markers for intra-scc deps
    scc_graph = {
        sha1(repr(sorted(scc)))[:16]: {m: {} for m in scc}
        for scc in graph_components
    }

    for scc_id, scc in scc_graph.items():
        for start in scc.keys():
            for next in scc.keys():
                # Note that we DO NOT provide a default marker here because this
                # is a dependency edge which may not actually exist and we don't
                # want to falsely insert edges/markers.
                next_marks = graph.get(start, {}).get(next, {})
                scc_graph[scc_id][next].update(next_marks)

        # Ensure that everything has at least the no-op marker
        for next in scc.keys():
            if len(scc_graph[scc_id][next].keys()) == 0:
                scc_graph[scc_id][next].update({"": 1})

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
    """Parses a requirement string into a list of dependency-marker pairs.

    This function parses a PEP 508 requirement string (e.g.,
    "requests[security]>=2.0; python_version < '3.8'") and converts it into a
    list of pairs, where each pair contains a `Dependency` tuple and a `Marker`
    string.

    Args:
        req_string: The requirement string to parse.
        version_map: A dictionary mapping package names to their default version
            dependency tuples.

    Returns:
        A list of tuples, where each tuple is `(Dependency, Marker)`.
    """

    # 1. Split Requirement and Marker
    # Starlark split() often doesn't support maxsplit, so we use find() + slicing
    semicolon_idx = req_string.find(";")

    marker = ""
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
        " ": 1,
    }

    name_end_idx = len(req_part)

    for i in range(len(req_part)):
        char = req_part[i]
        if char in stop_chars:
            name_end_idx = i
            break

    pkg_name = normalize_name(req_part[:name_end_idx])

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
    v = version_map.get(pkg_name)
    if v == None:
        fail("Unable to resolve a default version for requirement {}".format(repr(req_string)))
    else:
        lock_id, pkg_name, version, _ = v

    # 5. Construct results
    # Each result is ((name, ver, extra), marker)
    results = []

    # Base requirement
    base_dep = (lock_id, pkg_name, version, "__base__")
    results.append((base_dep, marker or ""))

    # Extras
    for e in extras:
        dep = (lock_id, pkg_name, version, e)
        results.append((dep, marker or ""))

    return results

def _collect_activated_extras(project_data, default_versions, graph):
    """Collects the set of transitively activated extras for each configuration.

    This function determines the full set of extras that are activated for each
    dependency group defined in the `pyproject.toml`. It performs a transitive
    traversal of the dependency graph to find all extras that are pulled in by
    the initial set of requirements.

    Args:
        project_data: The parsed content of the `pyproject.toml` file.
        default_versions: A dictionary mapping package names to their default
            version dependency tuples.
        graph: The dependency graph, as returned by `_build_marker_graph`.

    Returns:
        A tuple containing:
        - A dictionary of configuration names.
        - A dictionary mapping each dependency to a dictionary of configurations
          that activate it, which in turn maps to a dictionary of the extra
          dependencies and their markers. The structure is:
          `{dep: {cfg: {extra_dep: {marker: 1}}}}`.
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
    """Collates activated extras by package name, configuration, and version.

    This function transforms the `activated_extras` map into a more convenient
    structure that groups different versions of the same package together.

    Args:
        activated_extras: The map of activated extras, as returned by
            `_collect_activated_extras`.

    Returns:
        A dictionary mapping package names to configurations, versions, and
        markers. The structure is: `{name: {config: {version: {marker: 1}}}}`.
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
    """Collects all unique marker expressions from the dependency graph.

    Args:
        graph: The dependency graph.

    Returns:
        A dictionary mapping each unique marker expression to its SHA-1 hash.
    """
    acc = {}
    for _dep, nexts in graph.items():
        for _next, markers in nexts.items():
            for marker in markers.keys():
                # sha1 is "expensive" so we minimize it
                if marker and marker not in acc:
                    acc[marker] = sha1(marker)

    return acc

def _collect_configurations(lock):
    """Collects all unique platform configurations from the wheels in a lockfile.

    This function identifies all the unique combinations of Python implementation,
    platform, and ABI from the wheel filenames in the lockfile.

    Args:
        lock: The parsed content of the `uv.lock` file.

    Returns:
        A dictionary mapping configuration strings (e.g.,
        "cp39-manylinux_2_17_x86_64-cp39") to a list of `config_setting`
        labels that define the configuration.
    """
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
    """Collects all pre-built wheels (bdists) from a lockfile.

    Args:
        lock_data: The parsed content of the `uv.lock` file.

    Returns:
        A tuple containing:
        - A dictionary mapping repository names for the wheels to their bdist
          specifications.
        - A dictionary mapping the hash of each wheel to its repository label.
    """
    bdist_specs = {}
    bdist_table = {}
    for package in lock_data.get("package", []):
        for bdist in package.get("wheels", []):
            bdist_repo_name = "whl___{}__{}".format(package["name"], bdist["hash"].split(":")[1][:16])
            bdist_specs[bdist_repo_name] = bdist
            bdist_table[bdist["hash"]] = "@{}//file".format(bdist_repo_name)

    return bdist_specs, bdist_table

def _ensure_ref(maybe_ref):
    """Ensures a git ref starts with "ref/".

    Args:
        maybe_ref: The git ref string.

    Returns:
        The git ref string, prefixed with "ref/" if it is not already.
    """
    if maybe_ref == None:
        return None

    if not maybe_ref.startswith("ref/"):
        return "ref/" + maybe_ref

    return maybe_ref

def _parse_git_url(url):
    """Parses a git URL into a dictionary of `git_repository` arguments.

    This function is a simplified parser for git URLs that can extract a remote
    URL, a commit hash, or a ref. It supports URLs with fragments and query

    Args:
        url: The git URL to parse.

    Returns:
        A dictionary of `git_repository` arguments.
    """

    # 1. Handle Fragment (anything after #)
    # URL: https://github.com/user/repo.git#c7076a0...
    remote_and_query, hash_sep, fragment = url.partition("#")

    # 2. Handle Query Parameters (anything after ?)
    # URL: https://github.com/user/repo.git?rev=refs/pull/64/head
    remote_base, query_sep, query_string = remote_and_query.partition("?")

    kwargs = {"remote": remote_base}
    rev = ""
    ref = ""

    # 3. Extract revision from Fragment
    if fragment:
        rev = fragment

        # 4. Extract revision from Query String (if fragment wasn't present)
    elif query_string:
        params = {}

        # Manually parse query string for 'rev=' or 'ref='
        pairs = query_string.split("&")
        for pair in pairs:
            k, v = pair.split("=", 1)

            # FIXME: Better urldecode
            params[k] = v.replace("%2F", "/").replace("%2f", "/")

        if "ref" in params:
            ref = params["ref"]

        if "commit" in params:
            rev = params["commit"]

    # 5. Determine if the revision is a commit, tag, or branch
    if rev:
        kwargs["commit"] = rev
    elif ref:
        kwargs["ref"] = _ensure_ref(ref)

    return kwargs

def _try_git_to_http_archive(git_cfg):
    """Tries to convert a `git_repository` configuration to an `http_archive`.

    This function attempts to convert a `git_repository` configuration to an
    `http_archive` configuration for well-known git hosting services like
    GitHub. This is useful for performance, as downloading a tarball over HTTP
    is generally faster than cloning a git repository.

    Args:
        git_cfg: A dictionary of `git_repository` arguments.

    Returns:
        A dictionary of `http_archive` arguments, or `None` if the conversion
        is not possible.
    """

    if "https://github.com/" in git_cfg["remote"]:
        url = git_cfg["remote"].replace("git+", "").replace(".git", "").rstrip("/")
        if "commit" in git_cfg:
            url = "{}/archive/{}.tar.gz".format(url, git_cfg["commit"])
            return {
                "url": url,
            }
        elif "ref" in git_cfg:
            url = "{}/archive/{}.tar.gz".format(url, git_cfg["tag"])
            return {
                "url": url,
            }

    # FIXME: Support gitlab, other hosts?

def _collect_sdists(lock_id, lock_data):
    """Collects all source distributions (sdists) from a lockfile.

    Args:
        lock_id: A unique identifier for the lockfile.
        lock_data: The parsed content of the `uv.lock` file.

    Returns:
        A tuple containing:
        - A dictionary mapping repository names for the sdists to their
          specifications.
        - A dictionary mapping sdist build keys to their repository labels.
    """
    sdist_specs = {}
    sdist_table = {}
    for package in lock_data.get("package", []):
        k = "sdist_build__{}__{}__{}".format(lock_id, package["name"], package["version"].replace(".", "_"))
        if "sdist" in package:
            sdist = package["sdist"]
            sdist_repo_name = "sdist__{}__{}".format(package["name"], sdist["hash"].split(":")[1][:16])
            sdist_specs[sdist_repo_name] = {"file": sdist}
            sdist_table[k] = "@{}//file".format(sdist_repo_name)

        elif "git" in package["source"]:
            git_url = package["source"]["git"]
            git_cfg = _parse_git_url(git_url)

            sdist_cfg = _try_git_to_http_archive(git_cfg)
            sdist_repo_name = "sdist_git__{}__{}".format(package["name"], sha1(git_url)[:16])
            sdist_table[k] = "@{}//file".format(sdist_repo_name)

            if sdist_cfg:
                sdist_specs[sdist_repo_name] = {"file": sdist_cfg}

            else:
                sdist_specs[sdist_repo_name] = {"git": git_cfg}

    return sdist_specs, sdist_table

def _resolve(package, lock_id, default_versions):
    name = normalize_name(package["name"])
    if "version" in package:
        return (lock_id, name, package["version"].replace(".", "_"), "__base__")
    elif name in default_versions:
        return default_versions[name]
    else:
        fail("Unable to identify id for package {} for lock {}".format(package, lock_id, pprint(default_versions)))

def _process_overridden_packages(mod, project, lock_id, default_versions, install_table):
    # FIXME: This inner join is correct and easy, but it doesn't allow us to warn if there are annotations that don't join.
    for override in mod.tags.override_package:
        if override.lock == project.lock:
            v = override.version or default_versions.get(normalize_name(override.name))
            if not v:
                fail("Overridden project {} neither specifies a version nor has an implied singular version in the lockfile!\n{}".format(override.name, project.lock))
            k = (lock_id, normalize_name(override.name), v, "__base__")
            install_table[k] = str(override.target)

def _process_lock_file(module_ctx, mod, project, lock_id, lock_data, default_versions, install_table, sdist_table, sbuild_specs, install_cfgs, project_name):
    lock_build_dep_anns = {}
    for ann in mod.tags.unstable_annotate_packages:
        if ann.lock == project.lock:
            annotations = toml.decode_file(module_ctx, ann.src)
            for package in annotations.get("package", []):
                k = _resolve(package, lock_id, default_versions)
                deps = []
                for dep in package.get("build-dependencies", []):
                    deps.append(_resolve(dep, lock_id, default_versions))
                lock_build_dep_anns[k] = deps

    # Lazily evaluated cache
    lock_build_deps = None

    for package in lock_data.get("package", []):
        install_key = (lock_id, package["name"], package["version"], "__base__")

        if "editable" in package["source"]:
            # Don't generate a sdist build or anything else for the self-package
            if package["name"] == normalize_name(project_name):
                continue
            elif install_key in install_table:
                continue
            else:
                fail("Virtual package {} in lockfile {} doesn't have a mandatory `uv.override_package()` annotation!".format(package["name"], project.lock))

        k = "whl_install__{}__{}__{}".format(lock_id[:16], package["name"], package["version"].replace(".", "_"))
        install_table[install_key] = "@{}//:install".format(k)
        sbuild_id = "sdist_build__{}__{}__{}".format(lock_id[:16], package["name"], package["version"].replace(".", "_"))
        sdist = sdist_table.get(sbuild_id)

        # WARNING: Loop invariant; this flag needs to be False by
        # default and set if we do a build.
        has_sbuild = False

        # HACK: If there's a -none-any wheel for the package, then
        # we can actually skip creating the sdist build because
        # we'll never use it. This allows projects which can do
        # anyarch builds from bdists to avoid providing build deps.
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
                        for it in _extract_requirement_marker_pairs(req, default_versions)
                    ]

                build_deps = lock_build_deps

            sbuild_specs[sbuild_id] = struct(
                src = sdist,
                deps = [
                    "@{}__{}//:{}__{}".format(lock_id, bdep[1], bdep[2].replace(".", "_"), bdep[3])
                    for bdep in build_deps
                ],
                # FIXME: Check annotations
                is_native = False,
                version = package["version"],
            )

            has_sbuild = True

        install_cfgs[k] = struct(
            whls = {whl["url"].split("/")[-1].split("?")[0].split("#")[0]: sdist_table.get(whl["hash"]) for whl in package.get("wheels", [])},
            sbuild = "@{}//:whl".format(sbuild_id) if has_sbuild else None,
        )

def _parse_single_project(module_ctx, mod, project, hub_specs, lock_cfgs, hub_cfgs, marker_specs, whl_configurations, sdist_specs, sdist_table, bdist_specs, bdist_table, sbuild_specs, install_cfgs, install_table, project_set):
    project_data = toml.decode_file(module_ctx, project.pyproject)
    lock_data = toml.decode_file(module_ctx, project.lock)

    # This SHOULD be stable enough.
    # We'll rebuild the lock hub whenever the toml changes.
    # Reusing the name is fine.
    lock_stamp = sha1(repr(project.lock))[:16]
    lock_id = "lockfile__" + lock_stamp

    def _name(k):
        if k[3] == "__base__":
            return "@{}//:{}__{}".format(lock_id, k[1], k[2].replace(".", "_"))
        else:
            return "@{}//:{}__{}__extra__{}".format(lock_id, k[1], k[2].replace(".", "_"), normalize_name(k[3]))

    # Read these from the project or honor the module state
    project_name = project.name or project_data["project"]["name"]

    # FIXME: Error if this wasn't provided and the version is marked as dynamic
    project_version = project.version or project_data["project"]["version"]

    project_set[project_name] = 1

    if project.hub_name not in hub_specs:
        fail("Project {} in {} refers to hub {} which is not configured for that module. Please declare it.".format(project_name, mod.name, project.hub_name))

    if lock_id not in lock_cfgs:
        default_versions, lock_data = _normalize_deps(lock_id, lock_data)

        _process_overridden_packages(mod, project, lock_id, default_versions, install_table)

        marker_graph = _build_marker_graph(lock_id, lock_data)

        marker_specs.update(_collect_markers(marker_graph))

        bd, bt = _collect_bdists(lock_data)
        bdist_specs.update(bd)
        bdist_table.update(bt)

        sd, st = _collect_sdists(lock_stamp, lock_data)
        sdist_specs.update(sd)
        sdist_table.update(st)

        whl_configurations.update(_collect_configurations(lock_data))

        _process_lock_file(module_ctx, mod, project, lock_id, lock_data, default_versions, install_table, sdist_table, sbuild_specs, install_cfgs, project_name)

        dep_to_scc, scc_graph, scc_deps = _collect_sccs(marker_graph)

        # Rebuild the SCC graph to point to member installs
        #
        # This is a bit tricky because _extras_ which have no install
        # COULD be members of the SCC. We handle this by recognizing
        # that an extra is a group of deps we splice in potentially
        # conditionally, so all we need to do here is to recognize that
        # the package is virtual (has no install) and skip it. scc_deps
        # already handles the set of external edges, which will include
        # the set of external edges from component extras.
        scc_graph = {
            scc_id: {
                install_table[m]: v
                for m, v in members.items()
                # Extras etc. have no install table presence
                if m in install_table
            }
            for scc_id, members in scc_graph.items()
        }

        lock_cfgs[lock_id] = struct(
            default_versions = {
                k: _name(v)
                for k, v in default_versions.items()
            },
            dep_to_scc = {
                _name(k).split(":")[1]: v
                for k, v in dep_to_scc.items()
            },
            scc_deps = {
                k: {
                    _name(d).split("//")[1]: markers
                    for d, markers in deps.items()
                }
                for k, deps in scc_deps.items()
            },
            scc_graph = scc_graph,
        )

    else:
        cfg = lock_cfgs[lock_id]
        default_versions = cfg.default_versions
        dep_to_scc = cfg.dep_to_scc
        scc_graph = cfg.scc_graph
        scc_deps = cfg.scc_deps

    configuration_names, activated_extras = _collect_activated_extras(project_data, default_versions, marker_graph)
    version_activations = _collate_versions_by_name(activated_extras)

    # Filter out the project itself
    version_activations.pop(project_name)

    activated_extras = {
        _name(pkg): {
            cfg: {
                _name(extra): markers
                for extra, markers in extra_cfgs.items()
            }
            for cfg, extra_cfgs in pkg_cfgs.items()
        }
        for pkg, pkg_cfgs in activated_extras.items()
        if pkg[1] != project_name
    }

    version_activations = {
        cfg: {
            pkg: {
                _name(version): markers
                for version, markers in versions.items()
            }
            for pkg, versions in packages.items()
            if pkg[1] != project_name
        }
        for cfg, packages in version_activations.items()
    }

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

def parse_projects(module_ctx, hub_specs):
    """Parses all `uv.project()` declarations from all modules.

    This function is the core of the module extension's logic. It iterates
    through all the `uv.project()` declarations, parses the `pyproject.toml` and
    `uv.lock` files, and builds up the complete dependency graph.

    Args:
        module_ctx: The Bazel module context.
        hub_specs: A dictionary of hub specifications.

    Returns:
        A struct containing all the parsed information, including the dependency
        graph, SCCs, and configurations for all the repository rules that need
        to be generated.
    """

    lock_cfgs = {}
    hub_cfgs = {}
    marker_specs = {}
    whl_configurations = {}

    sdist_specs = {}
    sdist_table = {}

    bdist_specs = {}
    bdist_table = {}

    sbuild_specs = {}

    install_cfgs = {}
    install_table = {}

    project_set = {}

    # FIXME: Collect build deps files/annotations

    # Collect all hubs, ensure we have no dupes
    for mod in module_ctx.modules:
        for project in mod.tags.project:
            _parse_single_project(module_ctx, mod, project, hub_specs, lock_cfgs, hub_cfgs, marker_specs, whl_configurations, sdist_specs, sdist_table, bdist_specs, bdist_table, sbuild_specs, install_cfgs, install_table, project_set)

    return struct(
        lock_cfgs = lock_cfgs,
        hub_cfgs = hub_cfgs,
        install_cfgs = install_cfgs,
        sbuild_cfgs = sbuild_specs,
        marker_cfgs = marker_specs,
        whl_cfgs = whl_configurations,
        sdist_cfgs = sdist_specs,
        bdist_cfgs = bdist_specs,
        project_set = project_set,
    )
