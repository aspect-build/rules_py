load("//uv/private:sha1.bzl", "sha1")
load("//uv/private/graph:sccs.bzl", "sccs")

def collect_sccs(graph):
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
