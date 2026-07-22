load("//uv/private:normalize_version.bzl", "normalize_version")
load("//uv/private/graph:sccs.bzl", "sccs")

def _derive_scc_id(scc_members, stems):
    """Derive a deterministic, readable SCC id from the SCC's members.

    A lone base package (the overwhelmingly common case) gets
    `<name>__<version>`; a genuine cycle is named by its member packages.
    `stems` disambiguates repeat stems with a `__v<n>` suffix.
    """
    if len(scc_members) == 1 and scc_members[0][3] == "__base__":
        member = scc_members[0]
        stem = "{}__{}".format(member[1], normalize_version(member[2]))
    else:
        names = sorted([m[1] for m in scc_members])
        if len(names) > 4:
            names = names[:4] + ["and_{}_more".format(len(scc_members) - 4)]
        stem = "cycle__" + "__".join(names)
    n = stems.get(stem, 0)
    stems[stem] = n + 1
    return stem if n == 0 else "{}__v{}".format(stem, n)

def collect_sccs(marker_graph, id_state = None):
    """Computes Strongly Connected Components (SCCs) for a dependency marker_graph.

    This function takes a dependency marker_graph and identifies all the SCCs, which
    are groups of packages that have cyclic dependencies on each other.

    Args:
        marker_graph: The dependency marker_graph, as returned by `build_marker_graph`.
        {pkg: {dep: {marker: 1}}}
        id_state: dict carrying SCC id intern state. Pass the same dict for
        every configuration of one project: identical SCC content reuses one
        id (the caller aggregates by id), while an SCC with the same members
        but different external deps/markers gets a distinct id.

    Returns:
        A tuple containing:
        - A dictionary mapping each dependency to the ID of the SCC that
          contains it.
        - A dictionary representing the marker_graph of SCCs, where the keys are SCC IDs
          and the values are dictionaries of member dependencies and their
          markers.
        - A dictionary mapping each SCC ID to its direct, non-member
          dependencies.
    """

    all_nodes = set()
    for pkg, deps in marker_graph.items():
        all_nodes.add(pkg)
        for dep in deps.keys():
            all_nodes.add(dep)

    simplified_graph = {node: [] for node in all_nodes}
    for pkg, deps in marker_graph.items():
        simplified_graph[pkg] = list(deps.keys())

    graph_components = sccs(simplified_graph)

    # Split each SCC's edges into external deps and intra-member deps in
    # one pass, merging markers per target.
    scc_info_list = []
    for scc_members in graph_components:
        member_set = {m: True for m in scc_members}
        raw_scc_deps = {}
        intra_deps = {}
        for member in scc_members:
            for dep, markers in marker_graph.get(member, {}).items():
                target = intra_deps if dep in member_set else raw_scc_deps
                target.setdefault(dep, {}).update(markers)
        scc_info_list.append((scc_members, raw_scc_deps, intra_deps))

    new_scc_graph = {}
    dep_to_scc = {}
    final_scc_deps = {}  # This will store the scc_deps with the new keys

    if id_state == None:
        id_state = {}
    interned_ids = id_state.setdefault("ids", {})
    id_stems = id_state.setdefault("stems", {})

    for scc_members, raw_scc_deps, intra_deps in scc_info_list:
        # Intern the scc_id by full content: distinct (members, deps, markers)
        # content must map to distinct ids, identical content to one id.
        content_key = repr(sorted(scc_members)) + ";" + repr(sorted(raw_scc_deps.items()))
        new_scc_id = interned_ids.get(content_key)
        if new_scc_id == None:
            new_scc_id = _derive_scc_id(scc_members, id_stems)
            interned_ids[content_key] = new_scc_id

        # Build the new scc_graph entry
        new_scc_graph[new_scc_id] = {m: {} for m in scc_members}

        # Populate dep_to_scc
        for member in scc_members:
            dep_to_scc[member] = new_scc_id

        # Populate final_scc_deps
        final_scc_deps[new_scc_id] = raw_scc_deps

        # Merge the intra-member markers collected in the split above.
        for next, next_marks in intra_deps.items():
            new_scc_graph[new_scc_id][next].update(next_marks)

        # Ensure that everything has at least the no-op marker
        for next in scc_members:
            if len(new_scc_graph[new_scc_id][next].keys()) == 0:
                new_scc_graph[new_scc_id][next].update({"": 1})

    return dep_to_scc, new_scc_graph, final_scc_deps

def combine_markers(lefts, rights):
    """
    Combine two sets of markers under _and_.

    If `a[b]; m` implies some `b; n`, then `a` implies `b` IFF `m and n`. It
    would be incorrect to disregard either the left or right markers, as either
    case of doing so could lead to an unsatisfiable false dependency.
    """

    acc = {}

    def _and(l, r):
        """
        We use "" as the empty/True marker, so if either side is true then we
        need to return the other side.
        """

        if l == "":
            return r
        elif r == "":
            return l
        else:
            return "({}) and ({})".format(l, r)

    for l in lefts.keys():
        for r in rights.keys():
            acc[_and(l, r)] = 1

    return acc

def activate_extras(marker_graph, activated_extras, cfg):
    """
    Configure an unconfigured marker graph by activating extras.

    Produce a _new_ graph without modifying the original which:
    - Merges all active extras into their base packages (add deps)
    - Translates all deps on extras to deps on the base package
    - Removes all extras pesudo-packages
    """

    acc = {}

    for pkg, marked_deps in marker_graph.items():
        # Ignore extra pseudo-packages
        if pkg[3] != "__base__":
            continue

        # Packages may have no deps so we have to create this here
        acc.setdefault(pkg, {})

        for dep, markers in list(marked_deps.items()):
            # Normalize all deps to deps on the base package
            normalized_dep = (dep[0], dep[1], dep[2], "__base__")
            acc[pkg].setdefault(normalized_dep, {}).update(markers)

        # For the current (base!) package, look up the closure of activated
        # extras and merge the _dependencies_ of those extras in.
        extras = activated_extras.get(pkg, {}).get(cfg, {})
        for extra, extra_markers in extras.items():
            # Merge in deps from the requested extra
            for implied_dep, implied_markers in marker_graph.get(extra, {}).items():
                # Normalize since the source graph isn't
                normalized_implied_dep = (implied_dep[0], implied_dep[1], implied_dep[2], "__base__")
                acc[pkg].setdefault(normalized_implied_dep, {}).update(combine_markers(extra_markers, implied_markers))

    return acc
