"""Graph utilities for processing dependency marker graphs from uv.lock files.

This module provides functions to collapse strongly connected components,
combine PEP 508 markers under logical conjunction, and activate optional
extras into a concrete dependency graph.
"""

load("//uv/private:sha1.bzl", "sha1")
load("//uv/private/graph:sccs.bzl", "sccs")

def collect_sccs(marker_graph):
    """Computes Strongly Connected Components (SCCs) for a dependency graph.

    Identifies cyclic groups of packages, then rebuilds the graph so that each
    SCC becomes a single node. Intra-SCC edges preserve their original markers,
    while inter-SCC dependencies are aggregated per SCC.

    Args:
        marker_graph: A dependency graph mapping package tuples to dicts of
            dependencies and their markers: `{pkg: {dep: {marker: 1}}}`.

    Returns:
        A tuple `(dep_to_scc, new_scc_graph, final_scc_deps)` where:
        - `dep_to_scc` maps each original package tuple to the SCC ID that
          contains it.
        - `new_scc_graph` maps each SCC ID to a dict of its member packages
          and the markers between them.
        - `final_scc_deps` maps each SCC ID to its aggregated external
          dependencies and markers.
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

    scc_info_list = []
    for scc_members in graph_components:
        raw_scc_deps = {}
        for member in scc_members:
            for dep, markers in marker_graph.get(member, {}).items():
                if dep not in scc_members:
                    raw_scc_deps.setdefault(dep, {}).update(markers)
        scc_info_list.append((scc_members, raw_scc_deps))

    new_scc_graph = {}
    dep_to_scc = {}
    final_scc_deps = {}

    for scc_members, raw_scc_deps in scc_info_list:
        sorted_raw_scc_deps_repr = repr(sorted(raw_scc_deps.items()))
        new_scc_id = sha1(repr(sorted(scc_members)) + ";" + sorted_raw_scc_deps_repr)[:16]

        new_scc_graph[new_scc_id] = {m: {} for m in scc_members}

        for member in scc_members:
            dep_to_scc[member] = new_scc_id

        final_scc_deps[new_scc_id] = raw_scc_deps

        for start in scc_members:
            for next in scc_members:
                next_marks = marker_graph.get(start, {}).get(next, {})
                new_scc_graph[new_scc_id][next].update(next_marks)

        for next in scc_members:
            if len(new_scc_graph[new_scc_id][next].keys()) == 0:
                new_scc_graph[new_scc_id][next].update({"": 1})

    return dep_to_scc, new_scc_graph, final_scc_deps

def combine_markers(lefts, rights):
    """Combines two sets of markers under logical AND.

    If `a` depends on `b` with marker `m`, and `b` depends on `c` with marker
    `n`, then `a` depends on `c` when `m and n` is satisfiable. Dropping either
    marker would create a false dependency.

    Args:
        lefts: A dictionary of marker strings `{marker: 1}`.
        rights: A dictionary of marker strings `{marker: 1}`.

    Returns:
        A dictionary of combined marker strings `{marker: 1}`.
    """
    acc = {}

    def _and(l, r):
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
    """Configures a marker graph by activating optional extras.

    Produces a new graph in which:
    - Active extras are merged into their base packages.
    - All dependencies are translated into dependencies on the `__base__`
      package of the target.
    - Extra pseudo-packages are removed entirely.

    Args:
        marker_graph: The unconfigured dependency graph.
        activated_extras: A nested dictionary mapping base package tuples to
            activated extras per configuration: `{pkg: {cfg: {extra: {marker: 1}}}}`.
        cfg: The configuration key to look up in `activated_extras`.

    Returns:
        A new dependency graph with extras resolved and normalized to
        `__base__` dependencies.
    """
    acc = {}

    for pkg, marked_deps in marker_graph.items():
        if pkg[3] != "__base__":
            continue

        acc.setdefault(pkg, {})

        for dep, markers in list(marked_deps.items()):
            normalized_dep = (dep[0], dep[1], dep[2], "__base__")
            acc[pkg].setdefault(normalized_dep, {}).update(markers)

        extras = activated_extras.get(pkg, {}).get(cfg, {})
        for extra, extra_markers in extras.items():
            for implied_dep, implied_markers in marker_graph.get(extra, {}).items():
                normalized_implied_dep = (implied_dep[0], implied_dep[1], implied_dep[2], "__base__")
                acc[pkg].setdefault(normalized_implied_dep, {}).update(combine_markers(extra_markers, implied_markers))

    return acc
