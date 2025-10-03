def sccs(graph):
    """
    Finds the strongly connected components (SCCs) of a directed graph via
    Kosaraju's algorithm modified to fit into Starlark.

    Args:
        graph: A dictionary representing the adjacency list of the graph.

    Returns:
        A list of lists, where each inner list represents an SCC.
    """
    nodes = list(graph.keys())
    visited = {node: False for node in nodes}
    order = []

    # An upper bound for the number of steps we'll need on each pass. The
    # algorithm is actually linear time and the precise bound would be nodes +
    # edges, but this is simple and safe.
    #
    # Starlark doesn't have `**`. Oh well.
    bound = len(nodes) * len(nodes)

    # First DFS traversal to determine finishing times (post-order traversal)
    # The outer loop ensures we start a traversal for all unvisited nodes.
    for start_node in nodes:
        if not visited[start_node]:
            stack = [start_node]
            path_stack = []

            for _ in range(bound):
                if not stack:
                    break

                current_node = stack[-1]

                if not visited[current_node]:
                    visited[current_node] = True
                    path_stack.append(current_node)

                    for neighbor in graph.get(current_node, []):
                        if not visited[neighbor]:
                            stack.append(neighbor)
                elif current_node in path_stack:
                    path_stack.remove(current_node)
                    order.append(current_node)
                    stack.pop()

    # Create the transpose graph (all edges reversed)
    transpose_graph = {node: [] for node in nodes}
    for node in nodes:
        for neighbor in graph.get(node, []):
            transpose_graph[neighbor].append(node)

    # Reset visited flags for the second traversal
    visited = {node: False for node in nodes}
    sccs = []

    # Second DFS traversal on the transpose graph
    # We process nodes in the reverse of their finishing time order.
    # Each traversal finds a new SCC.
    for start_node in reversed(order):
        if not visited[start_node]:
            current_scc = []
            stack = [start_node]
            visited[start_node] = True

            for _ in range(bound):
                if not stack:
                    break

                current_node = stack.pop()
                current_scc.append(current_node)

                for neighbor in transpose_graph.get(current_node, []):
                    if not visited[neighbor]:
                        visited[neighbor] = True
                        stack.append(neighbor)

            sccs.append(current_scc)

    return [
        sorted(scc)
        for scc in sccs
    ]
