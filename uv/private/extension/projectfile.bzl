"""
Machinery specific to interacting with a pyproject.toml
"""

load("//uv/private:normalize_name.bzl", "normalize_name")
load("//uv/private/markers:pep508_evaluate.bzl", "evaluate", "tokenize")
load("//uv/private/versions:versions.bzl", "find_matching_version", "version_satisfies")
load(":dep_groups.bzl", "resolve_dependency_group_specs")
load(":graph_utils.bzl", "combine_markers")
load(":marker_simplify.bzl", "simplify_extra_marker")

def split_requirement_marker(req_string):
    """Split PEP 508 markers without treating URL path semicolons as markers."""
    direct_reference_idx = req_string.find("@")
    for i in range(len(req_string)):
        if req_string[i] != ";":
            continue
        if direct_reference_idx != -1 and direct_reference_idx < i:
            preceded_by_space = i > 0 and req_string[i - 1] in " \t\r\n"
            followed_by_space = i + 1 < len(req_string) and req_string[i + 1] in " \t\r\n"
            if not (preceded_by_space or followed_by_space):
                continue
        return req_string[:i].strip(), req_string[i + 1:].strip()
    return req_string.strip(), ""

def extract_requirement_marker_pairs(
        projectfile,
        lock_id,
        req_string,
        version_map,
        package_versions = {},
        preferred_versions = {},
        locked_urls = {},
        fail_if_missing = True):
    """Parses a requirement string into a list of dependency-marker pairs.

    This function parses a PEP 508 requirement string (e.g.,
    "requests[security]>=2.0; python_version < '3.8'") and converts it into a
    list of pairs, where each pair contains a `Dependency` tuple and a `Marker`
    string.

    Args:
        req_string: The requirement string to parse.
        version_map: A dictionary mapping package names to their default version
            dependency tuples.
        fail_if_missing: If True (the default), fail when the requirement's
            package can't be located in the lockfile. If False, return an empty
            list — useful for advisory requirements like the project-level
            `default_build_dependencies`, which may legitimately be absent
            from lockfiles that ship no sdists needing the build tooling.
        locked_urls: A dictionary mapping `(package_name, artifact_url)` to a
            locked dependency tuple, used to resolve direct references.

    Returns:
        A list of tuples, where each tuple is `(Dependency, Marker)`.
    """

    # uv-pep508's parse_url treats a semicolon inside a URL as a path
    # character; a direct-reference marker must have adjacent whitespace.
    req_part, marker = split_requirement_marker(req_string)

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
        "@": 1,
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
                    extras.append(normalize_name(clean_p).replace("_", "-"))
            remainder = remainder[close_idx + 1:]

    # 4. Look up version
    specifier = remainder.strip()
    if specifier.startswith("@"):
        # Direct references identify a locked artifact, not a version
        # constraint. Never fall back to a different locked version or URL.
        url = specifier[1:].strip()

        # Git uses semantically relevant fragments such as `#subdirectory=`.
        if not url.startswith("git+"):
            # uv stores hashes separately from URLs.
            url = url.split("#", 1)[0]
        v = locked_urls.get((pkg_name, url))
    else:
        v = preferred_versions.get(pkg_name)
        if v == None:
            v = version_map.get(pkg_name)
        if v == None:
            # For multi-version packages (e.g. conflicts), match the version
            # specifier against all known versions in the lockfile.
            pkg_vers = package_versions.get(pkg_name, {})
            if pkg_vers:
                match_spec = specifier if specifier else ">=0"
                candidates = {
                    ver: (lock_id, pkg_name, ver, "__base__")
                    for ver in pkg_vers.keys()
                }
                v = find_matching_version(match_spec, candidates)
    if v == None:
        if not fail_if_missing:
            return []
        fail("Unable to resolve a default version for requirement {} in {}".format(repr(req_string), projectfile))
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

def marker_can_apply(marker, requires_python):
    """Return whether a marker can apply to the project's Python versions."""
    if not marker:
        return True

    candidates = {
        "0.0.0": True,
        "2.7.0": True,
        "3.0.0": True,
        "3.11.0": True,
        "4.0.0": True,
    }

    # Python markers change truth only at a version boundary. Probe each
    # boundary and its neighbors, while leaving platform markers unresolved.
    for literal in tokenize(marker) + requires_python.split(","):
        literal = literal.strip("\"' ").lstrip("<>=!~ ").rstrip(".*")
        parts = literal.split(".")
        if not parts or not all([part.isdigit() for part in parts]):
            continue

        version = [int(part) for part in parts[:3]]
        version += [0] * (3 - len(version))
        for component in range(3):
            for offset in [-1, 0, 1]:
                adjacent = list(version)
                adjacent[component] += offset
                if adjacent[component] >= 0:
                    candidates["{}.{}.{}".format(*adjacent)] = True

    has_supported_candidate = False
    for candidate in candidates:
        if not version_satisfies(candidate, requires_python):
            continue

        has_supported_candidate = True
        major, minor, _patch = candidate.split(".")
        result = evaluate(
            marker,
            env = {
                "python_full_version": candidate,
                "python_version": "{}.{}".format(major, minor),
            },
            strict = False,
        )
        if result != False:
            return True

    # An unusual Python constraint must not silently discard a dependency when
    # none of the marker boundary candidates can represent its environment.
    return not has_supported_candidate

def _build_environment_marker(marker):
    """Resolve runtime-only extras outside an isolated build environment."""
    if "extra" not in tokenize(marker):
        return marker
    return simplify_extra_marker(marker, "")

def collect_build_dependency_markers(graph, requirements):
    """Collect the exact-version, marker-qualified isolated build closure."""
    marked_deps = {}
    worklist = []

    # Keep ancestors per path so cycles terminate without dropping another
    # marker-qualified route to the same locked package.
    for dep, marker in requirements:
        marker = _build_environment_marker(marker)
        if marker != None:
            worklist.append((dep, marker, {dep: True}))
    visited = {}
    idx = 0

    for _ in range(1000000):
        if idx == len(worklist):
            break

        dep, marker, path = worklist[idx]
        idx += 1
        state = (dep, marker)
        if state in visited:
            continue
        visited[state] = True

        base = (dep[0], dep[1], dep[2], "__base__")
        marked_deps.setdefault(base, {})[marker] = 1

        # Optional-dependency graph nodes do not link to the base package.
        if dep != base and base not in path:
            base_path = dict(path)
            base_path[base] = True
            worklist.append((base, marker, base_path))

        for next_dep, next_markers in graph.get(dep, {}).items():
            if next_dep in path:
                continue
            for edge_marker in next_markers:
                edge_marker = _build_environment_marker(edge_marker)
                if edge_marker == None:
                    continue
                for next_marker in combine_markers({marker: 1}, {edge_marker: 1}):
                    next_path = dict(path)
                    next_path[next_dep] = True
                    worklist.append((next_dep, next_marker, next_path))

    return marked_deps

def _extract_lockfile_group_versions(lock_id, lock_data):
    """Extracts resolved package versions per dependency group from the lockfile.

    uv.lock encodes the exact package versions selected for each dependency group
    in the root package's `dev-dependencies` section. This function builds a map
    that can be used as `preferred_versions` when resolving requirement strings.

    Args:
        lock_id: The lockfile identifier used in dependency tuples.
        lock_data: The parsed content of the `uv.lock` file.

    Returns:
        A dictionary mapping normalized group names to dictionaries of
        {package_name: (lock_id, package_name, version, "__base__")}.
    """
    result = {}
    for pkg in lock_data.get("package", []):
        if "virtual" not in pkg.get("source", {}):
            continue
        for raw_group_name, deps in pkg.get("dev-dependencies", {}).items():
            group_name = normalize_name(raw_group_name)
            for dep in deps:
                pkg_name = normalize_name(dep["name"])
                if "version" in dep:
                    result.setdefault(group_name, {})[pkg_name] = (lock_id, pkg_name, dep["version"], "__base__")
    return result

def collect_activated_extras(projectfile, lock_id, project_data, lock_data, default_versions, graph, package_versions = {}, locked_urls = {}):
    """Collects the set of transitively activated extras for each configuration.

    This function determines the full set of extras that are activated for each
    dependency group defined in the `pyproject.toml`. It performs a transitive
    traversal of the dependency graph to find all extras that are pulled in by
    the initial set of requirements, preserving the graph's existing
    dependency-edge markers. Isolated build extras are collected separately and
    never added to the runtime graph.

    Args:
        project_data: The parsed content of the `pyproject.toml` file.
        default_versions: A dictionary mapping package names to their default
            version dependency tuples.
        graph: The dependency graph, as returned by `build_marker_graph`.
        locked_urls: A dictionary mapping direct-reference URLs to locked
            dependencies.

    Returns:
        A tuple containing:
        - A dictionary of configuration names.
        - A dictionary mapping each dependency to a dictionary of configurations
          that activate it, which in turn maps to a dictionary of the extra
          dependencies and their markers. The structure is:
          `{dep: {cfg: {extra_dep: {marker: 1}}}}`.
    """

    # If no dependency-groups are specified, use the lock members manifest, or just the self-list
    dep_groups = project_data.get("dependency-groups", {
        project_data["project"]["name"]: lock_data.get("manifest", {}).get("members", [
            project_data["project"]["name"],
        ]),
    })

    # Normalize dep groups to our dependency triples (graph keys)
    normalized_dep_groups = {}

    # Builds up {package: {configuration: {extra: {marker: 1}}}}
    activated_extras = {}

    all_group_preferences = {}

    lockfile_group_versions = _extract_lockfile_group_versions(lock_id, lock_data)

    for group_name in dep_groups.keys():
        resolved_specs = resolve_dependency_group_specs(dep_groups, group_name)

        # Collect every selected version before resolving group requirements so
        # included groups and extras consistently follow this group's solution.
        group_preferences = dict(lockfile_group_versions.get(group_name, {}))

        for spec in resolved_specs:
            for dep, _marker in extract_requirement_marker_pairs(projectfile, lock_id, spec, default_versions, package_versions, group_preferences, locked_urls = locked_urls):
                group_preferences[dep[1]] = (dep[0], dep[1], dep[2], "__base__")

        all_group_preferences[group_name] = group_preferences

        for spec in resolved_specs:
            for dep, marker in extract_requirement_marker_pairs(projectfile, lock_id, spec, default_versions, package_versions, group_preferences, locked_urls = locked_urls):
                normalized_dep_groups.setdefault(group_name, []).append(dep)

                # Note that this is the base case for the reach set walk below
                # We do this here so it's easy to handle marker expressions
                base = (dep[0], dep[1], dep[2], "__base__")
                activated_extras.setdefault(base, {}).setdefault(group_name, {}).setdefault(dep, {}).update({marker: 1})

    for group_name, deps in normalized_dep_groups.items():
        worklist = list(deps)
        group_prefs = all_group_preferences.get(group_name, {})
        visited = {}
        idx = 0
        for _ in range(1000000):
            if idx == len(worklist):
                break

            it = worklist[idx]
            visited[it] = 1

            for next_dep, markers in graph.get(it, {}).items():
                pkg_name = next_dep[1]
                pref = group_prefs.get(pkg_name)
                target_dep = next_dep
                if pref and pref[2] != next_dep[2]:
                    target_dep = (next_dep[0], next_dep[1], pref[2], next_dep[3])

                base = (target_dep[0], target_dep[1], target_dep[2], "__base__")
                activated_extras.setdefault(base, {}).setdefault(group_name, {}).setdefault(target_dep, {}).update(markers)
                if target_dep not in visited:
                    visited[target_dep] = 1
                    worklist.append(target_dep)

            idx += 1

    return {it: 1 for it in dep_groups.keys()}, activated_extras

def collate_versions_by_name(activated_extras):
    """Collates activated extras by package name, configuration, and version.

    This function transforms the `activated_extras` map into a more convenient
    structure that groups different versions of the same package together.

    Args:
        activated_extras: The map of activated extras, as returned by
            `collect_activated_extras`.

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
