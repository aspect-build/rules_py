"""
Machinery specific to interacting with a pyproject.toml
"""

load("//uv/private:normalize_name.bzl", "normalize_name")
load("//uv/private/versions:versions.bzl", "find_matching_version")
load(":dep_groups.bzl", "resolve_dependency_group_specs")

def extract_requirement_marker_pairs(projectfile, lock_id, req_string, version_map, package_versions = {}, preferred_versions = {}):
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

    semicolon_idx = req_string.find(";")

    marker = ""
    if semicolon_idx != -1:
        marker_text = req_string[semicolon_idx + 1:].strip()
        if marker_text:
            marker = marker_text

        req_part = req_string[:semicolon_idx].strip()
    else:
        req_part = req_string.strip()

    if not req_part:
        return []

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
            remainder = remainder[close_idx + 1:]

    v = preferred_versions.get(pkg_name)
    if v == None:
        v = version_map.get(pkg_name)
    if v == None:
        specifier = remainder.strip()
        pkg_vers = package_versions.get(pkg_name, {})
        if pkg_vers:
            match_spec = specifier if specifier else ">=0"
            candidates = {
                ver: (lock_id, pkg_name, ver, "__base__")
                for ver in pkg_vers.keys()
            }
            v = find_matching_version(match_spec, candidates)
    if v == None:
        fail("Unable to resolve a default version for requirement {} in {}".format(repr(req_string), projectfile))
    else:
        lock_id, pkg_name, version, _ = v

    results = []

    base_dep = (lock_id, pkg_name, version, "__base__")
    results.append((base_dep, marker or ""))

    for e in extras:
        dep = (lock_id, pkg_name, version, e)
        results.append((dep, marker or ""))

    return results

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

def collect_activated_extras(projectfile, lock_id, project_data, lock_data, default_versions, graph, package_versions = {}):
    """Collects the set of transitively activated extras for each configuration.

    This function determines the full set of extras that are activated for each
    dependency group defined in the `pyproject.toml`. It performs a transitive
    traversal of the dependency graph to find all extras that are pulled in by
    the initial set of requirements.

    Args:
        project_data: The parsed content of the `pyproject.toml` file.
        default_versions: A dictionary mapping package names to their default
            version dependency tuples.
        graph: The dependency graph, as returned by `build_marker_graph`.

    Returns:
        A tuple containing:
        - A dictionary of configuration names.
        - A dictionary mapping each dependency to a dictionary of configurations
          that activate it, which in turn maps to a dictionary of the extra
          dependencies and their markers. The structure is:
          `{dep: {cfg: {extra_dep: {marker: 1}}}}`.
    """

    dep_groups = project_data.get("dependency-groups", {
        project_data["project"]["name"]: lock_data.get("manifest", {}).get("members", [
            project_data["project"]["name"],
        ]),
    })

    normalized_dep_groups = {}

    activated_extras = {}

    all_group_preferences = {}

    lockfile_group_versions = _extract_lockfile_group_versions(lock_id, lock_data)

    for group_name in dep_groups.keys():
        resolved_specs = resolve_dependency_group_specs(dep_groups, group_name)

        group_preferences = dict(lockfile_group_versions.get(group_name, {}))

        for spec in resolved_specs:
            for dep, _marker in extract_requirement_marker_pairs(projectfile, lock_id, spec, default_versions, package_versions, group_preferences):
                group_preferences[dep[1]] = (dep[0], dep[1], dep[2], "__base__")

        all_group_preferences[group_name] = group_preferences

        for spec in resolved_specs:
            for dep, marker in extract_requirement_marker_pairs(projectfile, lock_id, spec, default_versions, package_versions, group_preferences):
                normalized_dep_groups.setdefault(group_name, []).append(dep)

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
            `_collect_activated_extras`.

    Returns:
        A dictionary mapping package names to configurations, versions, and
        markers. The structure is: `{name: {config: {version: {marker: 1}}}}`.
    """
    result = {}

    for id, configs in activated_extras.items():
        (lock_id, pkg_name, pkg_version, _) = id
        for cfg, deps in configs.items():
            version_markers = result.setdefault(pkg_name, {}).setdefault(cfg, {}).setdefault(id, {})

            for markers in deps.values():
                version_markers.update(markers)

    return result
