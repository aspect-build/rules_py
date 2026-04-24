"""Strongly connected components helpers."""

def sccs(graph):
    """Identify strongly connected components using Kosaraju's algorithm.

    This is a non-recursive, no-while-loop implementation suitable for
    Starlark.  The algorithm works in three phases:
      1. A first DFS on the original graph records finishing times.
      2. The graph is transposed (all edges reversed).
      3. A second DFS on the transposed graph processes nodes in reverse
         finishing order to discover each SCC.

    Args:
      graph (dict): A mapping of nodes to their adjacency lists.

    Returns:
      A list of lists, where each inner list represents an SCC.
      Nodes inside each SCC are sorted lexicographically.
    """
    nodes = list(graph.keys())
    bound = len(nodes) * len(nodes)
    if not bound:
        bound = 1

    order = []
    visited = {node: 0 for node in nodes}
    for node in nodes:
        if visited[node] == 0:
            stack = [node]
            visited[node] = 1
            for _ in range(bound):
                if not stack:
                    break

                current_node = stack[-1]

                unvisited_neighbor = None
                for neighbor in graph.get(current_node, []):
                    if visited[neighbor] == 0:
                        unvisited_neighbor = neighbor
                        break

                if unvisited_neighbor:
                    visited[unvisited_neighbor] = 1
                    stack.append(unvisited_neighbor)
                else:
                    stack.pop()
                    visited[current_node] = 2
                    order.append(current_node)

    transpose_graph = {node: [] for node in nodes}
    for node in nodes:
        for neighbor in graph.get(node, []):
            transpose_graph.setdefault(neighbor, []).append(node)

    result = []
    visited = {node: False for node in nodes}
    for i in range(len(order)):
        start_node = order[len(order) - 1 - i]
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

            result.append(sorted(component))

    return result
