"""Machinery specific to interacting with a pyproject.toml."""

load("//uv/private:normalize_name.bzl", "normalize_name")
load("//uv/private/versions:versions.bzl", "find_matching_version")
load(":dep_groups.bzl", "resolve_dependency_group_specs")

def extract_requirement_marker_pairs(projectfile, lock_id, req_string, version_map, package_versions = {}):
    """Parses a PEP 508 requirement string into dependency-marker pairs.

    For example, `requests[security]>=2.0; python_version < '3.8'` is split
    into its base dependency and each requested extra, each paired with the
    corresponding marker.

    Args:
      projectfile:      path to the source project file (used for error messages).
      lock_id:          identifier of the lockfile being processed.
      req_string:       the PEP 508 requirement string to parse.
      version_map:      dict mapping normalized package names to their default
                        version dependency tuples.
      package_versions: optional dict of all known versions for a package,
                        used when the requirement specifies a version selector
                        that must be matched dynamically.

    Returns:
      A list of tuples `(Dependency, Marker)`, where `Dependency` is a tuple
      `(lock_id, pkg_name, version, extra)` and `Marker` is a string.
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

    v = version_map.get(pkg_name)
    if v == None:
        specifier = remainder.strip()
        pkg_vers = package_versions.get(pkg_name, {})
        if specifier and pkg_vers:
            candidates = {
                ver: (lock_id, pkg_name, ver, "__base__")
                for ver in pkg_vers.keys()
            }
            v = find_matching_version(specifier, candidates)
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

def collect_activated_extras(projectfile, lock_id, project_data, lock_data, default_versions, graph, package_versions = {}):
    """Collects the transitively activated extras for each dependency group.

    The function determines which extras are pulled in by the initial set of
    requirements declared in `pyproject.toml` and performs a worklist traversal
    of the dependency graph to find the full transitive closure.

    Args:
      projectfile:       path to the source project file (used for diagnostics).
      lock_id:           identifier of the lockfile being processed.
      project_data:      parsed content of the `pyproject.toml` file.
      lock_data:         parsed content of the lockfile.
      default_versions:  dict mapping package names to default version tuples.
      graph:             dependency graph as returned by `build_marker_graph`.
      package_versions:  optional dict of all known versions for a package.

    Returns:
      A tuple `(configs, activated_extras)` where:
        * `configs` is a dict whose keys are configuration (group) names.
        * `activated_extras` has the shape
          `{dep_base: {cfg: {extra_dep: {marker: 1}}}}`.
    """
    dep_groups = project_data.get("dependency-groups", {
        project_data["project"]["name"]: lock_data.get("manifest", {}).get("members", [
            project_data["project"]["name"],
        ]),
    })

    normalized_dep_groups = {}
    activated_extras = {}

    for group_name in dep_groups.keys():
        normalized_dep_groups[group_name] = []
        resolved_specs = resolve_dependency_group_specs(dep_groups, group_name)
        for spec in resolved_specs:
            for dep, marker in extract_requirement_marker_pairs(projectfile, lock_id, spec, default_versions, package_versions):
                normalized_dep_groups[group_name].append(dep)
                base = (dep[0], dep[1], dep[2], "__base__")
                activated_extras.setdefault(base, {}).setdefault(group_name, {}).setdefault(dep, {}).update({marker: 1})

    for group_name, deps in normalized_dep_groups.items():
        worklist = list(deps)
        visited = {}
        idx = 0
        for _ in range(1000000):
            if idx == len(worklist):
                break

            it = worklist[idx]
            visited[it] = 1

            for next, markers in graph.get(it, {}).items():
                base = (next[0], next[1], next[2], "__base__")
                activated_extras.setdefault(base, {}).setdefault(group_name, {}).setdefault(next, {}).update(markers)
                if next not in visited:
                    visited[next] = 1
                    worklist.append(next)

            idx += 1

    return {it: 1 for it in dep_groups.keys()}, activated_extras

def collate_versions_by_name(activated_extras):
    """Collates activated extras by package name, configuration, and version.

    This transforms the `activated_extras` map into a structure that groups
    different versions of the same package together under each configuration.

    Args:
      activated_extras: the map returned by `collect_activated_extras`.

    Returns:
      A dictionary with the shape `{name: {config: {version_id: {marker: 1}}}}`.
    """
    result = {}

    for id, configs in activated_extras.items():
        (lock_id, pkg_name, pkg_version, _) = id
        for cfg, deps in configs.items():
            version_markers = result.setdefault(pkg_name, {}).setdefault(cfg, {}).setdefault(id, {})
            for markers in deps.values():
                version_markers.update(markers)

    return result
