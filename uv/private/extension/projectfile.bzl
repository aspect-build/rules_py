"""
Machinery specific to interacting with a pyproject.toml
"""

load("//uv/private:normalize_name.bzl", "normalize_name")
load("//uv/private/versions:versions.bzl", "find_matching_version")
load(":dep_groups.bzl", "resolve_dependency_group_specs")

def extract_requirement_marker_pairs(projectfile, lock_id, req_string, version_map, package_versions = {}, preferred_versions = {}, fail_if_missing = True):
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
            remainder = remainder[close_idx + 1:]

    # 4. Look up version
    # An exact requirement is authoritative. A dependency group's preferred
    # version cannot represent multiple versions selected by disjoint markers.
    specifier = remainder.strip()
    v = None
    if specifier.startswith("=="):
        pkg_vers = package_versions.get(pkg_name, {})
        candidates = {
            ver: (lock_id, pkg_name, ver, "__base__")
            for ver in pkg_vers.keys()
        }
        v = find_matching_version(specifier, candidates)
    if v == None:
        v = preferred_versions.get(pkg_name)
    if v == None:
        v = version_map.get(pkg_name)
    if v == None:
        # For multi-version packages (e.g. conflicts), match the version
        # specifier against all known versions of this package in the lockfile.
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

def _marker_clause(marker):
    """Returns a canonical conjunction clause for a marker expression."""
    return () if marker == "" else (marker,)

def _combine_marker_clause(clause, marker):
    """Conjoins a clause with an edge marker without duplicating atoms."""
    if marker == "" or marker in clause:
        return clause
    return tuple(sorted(clause + (marker,)))

def _clause_marker(clause):
    """Renders a canonical conjunction clause as a marker expression."""
    if not clause:
        return ""
    if len(clause) == 1:
        return clause[0]
    return " and ".join(["({})".format(marker) for marker in clause])

def _add_minimal_clause(clauses, candidate):
    """Adds candidate unless an existing, less restrictive clause subsumes it."""
    for existing in clauses:
        if all([marker in candidate for marker in existing]):
            return None

    removed = []
    for existing in clauses:
        if all([marker in existing for marker in candidate]):
            removed.append(existing)
    for existing in removed:
        clauses.pop(existing)
    clauses[candidate] = 1
    return removed

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

    # If no dependency-groups are specified, use the lock members manifest, or just the self-list
    dep_groups = project_data.get("dependency-groups", {
        project_data["project"]["name"]: lock_data.get("manifest", {}).get("members", [
            project_data["project"]["name"],
        ]),
    })

    # Builds up {package: {configuration: {extra: {marker: 1}}}}
    activated_extras = {}

    # Minimal conjunction clauses under which each dependency is reachable,
    # per configuration. Keeping an antichain of clauses makes propagation
    # cycle-safe: revisiting a node through a cycle can only add restrictions,
    # so that path is subsumed by the path which first entered the cycle.
    reachable_clauses = {}

    all_group_preferences = {}

    lockfile_group_versions = _extract_lockfile_group_versions(lock_id, lock_data)

    for group_name in dep_groups.keys():
        resolved_specs = resolve_dependency_group_specs(dep_groups, group_name)

        group_preferences = dict(lockfile_group_versions.get(group_name, {}))

        direct_versions = {}
        for spec in resolved_specs:
            for dep, _marker in extract_requirement_marker_pairs(projectfile, lock_id, spec, default_versions, package_versions, group_preferences):
                direct_versions.setdefault(dep[1], {})[(dep[0], dep[1], dep[2], "__base__")] = 1

        for package, versions in direct_versions.items():
            if len(versions) == 1:
                group_preferences[package] = list(versions.keys())[0]
            elif package in group_preferences:
                group_preferences.pop(package)

        all_group_preferences[group_name] = group_preferences

        for spec in resolved_specs:
            for dep, marker in extract_requirement_marker_pairs(projectfile, lock_id, spec, default_versions, package_versions, group_preferences):
                # Note that this is the base case for the reach set walk below
                # We do this here so it's easy to handle marker expressions
                base = (dep[0], dep[1], dep[2], "__base__")
                dep_markers = activated_extras.setdefault(base, {}).setdefault(group_name, {}).setdefault(dep, {})
                clauses = reachable_clauses.setdefault(group_name, {}).setdefault(dep, {})
                clause = _marker_clause(marker)
                removed = _add_minimal_clause(clauses, clause)
                if removed != None:
                    for old_clause in removed:
                        dep_markers.pop(_clause_marker(old_clause))
                    dep_markers[_clause_marker(clause)] = 1

    for group_name, group_clauses in reachable_clauses.items():
        worklist = [
            (dep, clause)
            for dep, clauses in group_clauses.items()
            for clause in clauses
        ]
        group_prefs = all_group_preferences.get(group_name, {})

        # Every useful clause has a simple-path witness: following a cycle can
        # only add restrictions, so the clause at the cycle entry subsumes it.
        # Processing one graph edge per round therefore reaches a fixed point
        # after at most one round per node, plus one to drain terminal nodes.
        for _ in range(len(graph) + 1):
            if not worklist:
                break

            next_worklist = []
            for parent_dep, parent_clause in worklist:
                if parent_clause not in group_clauses[parent_dep]:
                    continue

                for next_dep, edge_markers in graph.get(parent_dep, {}).items():
                    pkg_name = next_dep[1]
                    pref = group_prefs.get(pkg_name)
                    target_dep = next_dep
                    if pref and pref[2] != next_dep[2]:
                        target_dep = (next_dep[0], next_dep[1], pref[2], next_dep[3])

                    base = (target_dep[0], target_dep[1], target_dep[2], "__base__")
                    target_markers = activated_extras.setdefault(base, {}).setdefault(group_name, {}).setdefault(target_dep, {})
                    target_clauses = group_clauses.setdefault(target_dep, {})

                    for edge_marker in edge_markers:
                        clause = _combine_marker_clause(parent_clause, edge_marker)
                        if clause in target_clauses:
                            continue
                        removed = _add_minimal_clause(target_clauses, clause)
                        if removed == None:
                            continue
                        for old_clause in removed:
                            target_markers.pop(_clause_marker(old_clause))
                        target_markers[_clause_marker(clause)] = 1
                        next_worklist.append((target_dep, clause))

            worklist = next_worklist

        if worklist:
            fail("Marker propagation did not converge for dependency group {} in {}".format(repr(group_name), projectfile))

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
