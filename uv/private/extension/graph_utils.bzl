load("//uv/private:sha1.bzl", "sha1")
load("//uv/private/graph:sccs.bzl", "sccs")

def collect_sccs(marker_graph):
    """Computes Strongly Connected Components (SCCs) for a dependency marker_graph.

    This function takes a dependency marker_graph and identifies all the SCCs, which
    are groups of packages that have cyclic dependencies on each other.

    Args:
        marker_graph: The dependency marker_graph, as returned by `_build_marker_graph`.
        {pkg: {dep: {marker: 1}}}

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

    # Now we need to rebuild markers for intra-scc deps
    # Data structure to hold scc_members and their raw deps
    scc_info_list = []
    for scc_members in graph_components:
        raw_scc_deps = {}
        for member in scc_members:
            for dep, markers in marker_graph.get(member, {}).items():
                if dep not in scc_members:  # Only consider external dependencies
                    raw_scc_deps.setdefault(dep, {}).update(markers)
        scc_info_list.append((scc_members, raw_scc_deps))

    new_scc_graph = {}
    dep_to_scc = {}
    final_scc_deps = {}  # This will store the scc_deps with the new keys

    for scc_members, raw_scc_deps in scc_info_list:
        # Generate the new scc_id
        # We need to sort the raw_scc_deps.items() to ensure consistent hashing
        sorted_raw_scc_deps_repr = repr(sorted(raw_scc_deps.items()))
        new_scc_id = sha1(repr(sorted(scc_members)) + ";" + sorted_raw_scc_deps_repr)[:16]

        # Build the new scc_graph entry
        new_scc_graph[new_scc_id] = {m: {} for m in scc_members}

        # Populate dep_to_scc
        for member in scc_members:
            dep_to_scc[member] = new_scc_id

        # Populate final_scc_deps
        final_scc_deps[new_scc_id] = raw_scc_deps

        # Now, rebuild markers for intra-scc deps for the new_scc_graph
        for start in scc_members:
            for next in scc_members:
                # Note that we DO NOT provide a default marker here because this
                # is a dependency edge which may not actually exist and we don't
                # want to falsely insert edges/markers.
                next_marks = marker_graph.get(start, {}).get(next, {})
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
            acc[pkg][normalized_dep] = markers

        # For the current (base!) package, look up the closure of activated
        # extras and merge the _dependencies_ of those extras in.
        extras = activated_extras.get(pkg, {}).get(cfg, {})
        for extra, extra_markers in extras.items():
            # Merge in deps from the requested extra
            for implied_dep, implied_markers in marker_graph.get(extra, {}).items():
                # Normalize since the source graph isn't
                normalized_implied_dep = (implied_dep[0], implied_dep[1], implied_dep[2], "__base__")
                acc[pkg][normalized_implied_dep] = combine_markers(extra_markers, implied_markers)

    return acc
