"""
Machinery specific to interacting with a pyproject.toml
"""

load("//uv/private:normalize_name.bzl", "normalize_name")
load("//uv/private/versions:versions.bzl", "find_matching_version")
load(":dep_groups.bzl", "resolve_dependency_group_specs")
load(":marker_simplify.bzl", "simplify_markers_for_extras")

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
    in the root package's `dev-dependencies` section. A group may legitimately
    lock the same package at several versions, each gated by a disjoint PEP 508
    marker (platform/python forks or uv conflict routing), so every entry is
    kept as a `(dep, marker)` candidate rather than collapsed to one version.

    Args:
        lock_id: The lockfile identifier used in dependency tuples.
        lock_data: The parsed content of the `uv.lock` file.

    Returns:
        A dictionary mapping normalized group names to dictionaries of
        {package_name: [((lock_id, package_name, version, "__base__"), marker)]},
        with candidates in lockfile order.
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
                    candidate = ((lock_id, pkg_name, dep["version"], "__base__"), dep.get("marker", ""))
                    result.setdefault(group_name, {}).setdefault(pkg_name, []).append(candidate)
    return result

def _atom_sets(markers):
    """Converts a `{marker: 1}` set into canonical conjunction form.

    Activation conditions are tracked as dicts keyed by sorted tuples of
    atomic marker expressions: each tuple is one conjunction, the dict is
    their disjunction, and the empty tuple is the always-true condition.
    Keeping conjunctions as canonical atom sets instead of formatted strings
    makes conjunction idempotent, so the reach-set walk below reaches a
    fixpoint even on dependency cycles instead of growing marker strings
    forever.

    Returns:
        A dict of `{atom_tuple: 1}` conditions.
    """
    return {((marker,) if marker else ()): 1 for marker in markers.keys()}

def _conjoin_conditions(lefts, rights):
    """Conjoins two atom-set conditions: cross product, union of atoms.

    Returns:
        A dict of `{atom_tuple: 1}` conditions.
    """
    acc = {}
    for l_atoms in lefts.keys():
        for r_atoms in rights.keys():
            merged = {atom: 1 for atom in l_atoms}
            merged.update({atom: 1 for atom in r_atoms})
            acc[tuple(sorted(merged.keys()))] = 1
    return acc

def _render_markers(conditions):
    """Renders atom-set conditions back into `{marker: 1}` strings.

    Returns:
        A dict of `{marker: 1}` PEP 508 marker strings.
    """
    acc = {}
    for atoms in conditions.keys():
        if len(atoms) == 1:
            acc[atoms[0]] = 1
        else:
            acc[" and ".join(["({})".format(atom) for atom in atoms])] = 1
    return acc

def _fan_out_candidates(dep, conditions, candidates):
    """Fans a dependency out over a group's marker-gated locked candidates.

    Each candidate version is emitted gated by the conjunction of the incoming
    atom-set conditions and the candidate's lockfile marker; uv guarantees
    candidates within a group carry disjoint markers, so at most one
    conjunction holds per environment.

    The candidates only cover the group's own locked entries for the package.
    When the dependency's version is not among them (a transitive lockfile
    resolution outside the dev-dependencies list), it is preserved as-is so
    environments where no candidate marker holds still wire a version.

    Returns:
        A list of `(dep, conditions)` pairs.
    """
    targets = [
        (
            (dep[0], dep[1], candidate[2], dep[3]),
            _conjoin_conditions(conditions, _atom_sets({candidate_marker: 1})),
        )
        for candidate, candidate_marker in candidates
    ]
    if dep[2] not in [candidate[2] for candidate, _ in candidates]:
        targets.append((dep, conditions))
    return targets

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

    # Normalize dep groups to our dependency triples (graph keys)
    normalized_dep_groups = {}

    # Builds up {package: {configuration: {extra: {marker: 1}}}}
    activated_extras = {}

    all_group_preferences = {}

    all_group_fanout_candidates = {}

    lockfile_group_versions = _extract_lockfile_group_versions(lock_id, lock_data)

    for group_name in dep_groups.keys():
        resolved_specs = resolve_dependency_group_specs(dep_groups, group_name)

        group_candidates = lockfile_group_versions.get(group_name, {})

        # A package the group locks under a marker — or at several marker-gated
        # versions — cannot be collapsed to an unconditional preference. Those
        # candidates fan out below, each gated by its lockfile marker, and the
        # final choice happens at build time in the decide_marker select()
        # layer. Only a single unconditional entry acts as a plain preference.
        fanout_candidates = {}
        group_preferences = {}
        for pkg_name, candidates in group_candidates.items():
            if len(candidates) == 1 and candidates[0][1] == "":
                group_preferences[pkg_name] = candidates[0][0]
            else:
                fanout_candidates[pkg_name] = candidates

        # Fanned-out packages still need *a* version so requirement specs
        # resolve without falling through to the specifier matcher, which
        # rejects legal forms such as direct references. The fan-out discards
        # this placeholder version and re-expands every candidate.
        resolution_versions = dict(group_preferences)
        resolution_versions.update({
            pkg_name: candidates[0][0]
            for pkg_name, candidates in fanout_candidates.items()
        })

        for spec in resolved_specs:
            for dep, _marker in extract_requirement_marker_pairs(projectfile, lock_id, spec, default_versions, package_versions, resolution_versions):
                if dep[1] not in fanout_candidates:
                    group_preferences[dep[1]] = (dep[0], dep[1], dep[2], "__base__")
                    resolution_versions[dep[1]] = group_preferences[dep[1]]

        all_group_preferences[group_name] = group_preferences
        all_group_fanout_candidates[group_name] = fanout_candidates

        for spec in resolved_specs:
            for dep, marker in extract_requirement_marker_pairs(projectfile, lock_id, spec, default_versions, package_versions, resolution_versions):
                candidates = fanout_candidates.get(dep[1])
                spec_condition = _atom_sets({marker: 1})
                seeds = _fan_out_candidates(dep, spec_condition, candidates) if candidates else [(dep, spec_condition)]

                # Note that this is the base case for the reach set walk below
                # We do this here so it's easy to handle marker expressions
                for seed_dep, seed_conditions in seeds:
                    normalized_dep_groups.setdefault(group_name, []).append((seed_dep, seed_conditions))

                    base = (seed_dep[0], seed_dep[1], seed_dep[2], "__base__")
                    activated_extras.setdefault(base, {}).setdefault(group_name, {}).setdefault(seed_dep, {}).update(_render_markers(seed_conditions))

    for group_name, deps in normalized_dep_groups.items():
        worklist = list(deps)
        group_prefs = all_group_preferences.get(group_name, {})
        group_fanout = all_group_fanout_candidates.get(group_name, {})

        # dep -> {atom_tuple: 1}: every condition the dep was already expanded
        # under. A node re-expands only for genuinely new conditions, which
        # both dedups the walk and bounds it: atom tuples are subsets of the
        # finite marker universe, so cycles saturate instead of diverging.
        expanded = {}
        idx = 0
        for _ in range(1000000):
            if idx == len(worklist):
                break

            it, conditions = worklist[idx]
            idx += 1

            known = expanded.setdefault(it, {})
            fresh = {atoms: 1 for atoms in conditions.keys() if atoms not in known}
            if not fresh:
                continue
            known.update(fresh)

            # If we reached this node via an extra, any `extra == '...'` marker
            # on outgoing edges can be resolved using that extra.
            origin_extra = it[3] if it[3] != "__base__" else None

            for next_dep, markers in graph.get(it, {}).items():
                pkg_name = next_dep[1]
                simplified_markers = simplify_markers_for_extras(markers, [origin_extra]) if origin_extra else markers

                # Conjoin the conditions that (newly) activate this node with
                # the edge's own markers, so transitive dependencies inherit
                # the gates of the fanned-out versions that pull them in.
                propagated = _conjoin_conditions(fresh, _atom_sets(simplified_markers))

                candidates = group_fanout.get(pkg_name)
                if candidates:
                    # Contradictory conjunctions decide to false at build
                    # time, leaving only the compatible version per env.
                    targets = _fan_out_candidates(next_dep, propagated, candidates)
                else:
                    pref = group_prefs.get(pkg_name)
                    target_dep = next_dep
                    if pref and pref[2] != next_dep[2]:
                        target_dep = (next_dep[0], next_dep[1], pref[2], next_dep[3])
                    targets = [(target_dep, propagated)]

                for target_dep, target_conditions in targets:
                    base = (target_dep[0], target_dep[1], target_dep[2], "__base__")

                    activated_extras.setdefault(base, {}).setdefault(group_name, {}).setdefault(target_dep, {}).update(_render_markers(target_conditions))

                    known_target = expanded.get(target_dep, {})
                    if any([atoms not in known_target for atoms in target_conditions.keys()]):
                        worklist.append((target_dep, target_conditions))

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
            # Ensure path exists: result[name][cfg][version] -> {marker: 1}
            # We use setdefault chain to traverse/create the nested dicts
            version_markers = result.setdefault(pkg_name, {}).setdefault(cfg, {}).setdefault(id, {})

            # deps is {dep_triple: {marker: 1}}
            # We aggregate all markers for this version (from base and extras)
            # into the single map for this version string.
            for markers in deps.values():
                version_markers.update(markers)

    return result
