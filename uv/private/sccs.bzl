"""
Strongly connected components helpers.
"""

def sccs(graph):
    """Identify strongly connected components.

    Uses Kosaraju's algorithm as the strategy. This is a non-recursive,
    no-while-loop implementation suitable for Starlark.

    Args:
        graph (dict): A mapping of nodes to their adjacencies.

    Returns:
        A list of lists, where each inner list represents an SCC.
        The components of each SCC are in lexically sorted order.
    """
    nodes = list(graph.keys())
    bound = len(nodes) * len(nodes)
    if not bound:
        bound = 1

    # First DFS traversal to determine finishing times (post-order traversal)
    order = []

    # visited can be 0 (unvisited), 1 (visiting), or 2 (finished)
    visited = {node: 0 for node in nodes}
    for node in nodes:
        if visited[node] == 0:
            stack = [node]
            visited[node] = 1
            for _ in range(bound):
                if not stack:
                    break

                current_node = stack[-1]

                # Find an unvisited neighbor
                unvisited_neighbor = None
                for neighbor in graph.get(current_node, []):
                    if visited[neighbor] == 0:
                        unvisited_neighbor = neighbor
                        break

                if unvisited_neighbor:
                    visited[unvisited_neighbor] = 1
                    stack.append(unvisited_neighbor)
                else:
                    # All neighbors visited, so we are done with this node
                    stack.pop()
                    visited[current_node] = 2
                    order.append(current_node)

    # Create the transpose graph (all edges reversed)
    transpose_graph = {node: [] for node in nodes}
    for node in nodes:
        for neighbor in graph.get(node, []):
            transpose_graph.setdefault(neighbor, []).append(node)

    # Second DFS traversal on the transpose graph
    sccs = []
    visited = {node: False for node in nodes}
    for i in range(len(order)):
        start_node = order[len(order) - 1 - i]  # reversed order
        if not visited[start_node]:
            component = []
            stack = [start_node]
            visited[start_node] = True

            for _ in range(bound):
                if not stack:
                    break

                current_node = stack.pop()
                component.append(current_node)

                for neighbor in transpose_graph.get(current_node, []):
                    if not visited[neighbor]:
                        visited[neighbor] = True
                        stack.append(neighbor)

            sccs.append(sorted(component))

    return sccs
