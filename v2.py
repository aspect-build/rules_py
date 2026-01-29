#!/usr/bin/env python3

from typing import List, Optional, TypedDict
import tomllib
import sys
from pprint import pprint
from hashlib import sha1 as _sha1

SdistSpec = dict
WheelSpec = dict

class DependencySpec(TypedDict):
    name: str
    version: Optional[str]
    marker: Optional[str]

class RequirementSpec(TypedDict):
    name: str
    sdist: Optional[SdistSpec]
    source: dict
    wheels: List[WheelSpec]
    version: str
    dependency: List[DependencySpec]


# Copying Bazel's struct
def struct(**kwargs):
    return type('struct', (object,), kwargs)
    

def fail(msg):
    raise ValueError(msg)
    
# Bridge to our sha1's signature
def sha1(txt):
    return _sha1(txt.encode()).hexdigest()

# from sccs.bzl
def sccs(graph):
    """Identify strongly connected components.

    Uses Kosaraju's algorithm as the strategy.

    Args:
        graph (dict): A mapping of nodes to their adjacencies.

    Returns:
        A list of lists, where each inner list represents an SCC.
        The components of each SCC are in lexically sorted order.
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
            temp_order = []

            for _ in range(bound):
                if not stack:
                    break

                current_node = stack.pop()
                temp_order.append(current_node)
                visited[current_node] = True

                neighbors = graph.get(current_node, [])
                for neighbor in neighbors:
                    if not visited[neighbor]:
                        stack.append(neighbor)

            order = order + list(reversed(temp_order))

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

####################################################################################################

def _normalize_deps(lock_data):
    """
    Normalize the lockfile.
    1. Compute the "default version" mapping
    2. Update all the dependency statements within the lockfile so they're version disambiguated
    """

    package_versions = {}
    for spec in lock_data.get("package", []):
        # spec: RequirementSpec

        # Collect all the versions first
        package_versions.setdefault(spec["name"], {})[spec["version"]] = 1

    default_versions = {
        requirement: list(versions.keys())[0]
        for requirement, versions in package_versions.items() if len(versions) == 1
    }

    def _fix_version(dep):
        if not "version" in dep:
            dep["version"] = default_versions.get(dep["name"])

    for spec in lock_data.get("package", []):
        for dep in spec.get("dependencies", []):
            _fix_version(dep)
        for extra_deps in spec.get("optional-dependencies", {}).values():
            for dep in extra_deps:
                _fix_version(dep)

    return package_versions, default_versions, lock_data

def _build_marker_graph(lock_data):
    """The graph is {(package, version, extra): {(package, version, extra): {marker: 1}}}.

    We convert dependencies which no extra list to dependencies on ["__base__"].
    We also ensure that every extra depends on the "__base__" configuration if itself.


    So writing `requests` is understood to be `requests[__base__]`, and
    `requests[foo]` is `requests[__foo__] -> requests[__base__]` which allows is
    to capture the same graph without having do splice in dependencies.

    At this point we also HAVE NOT done extras activation.
    """

    graph = {}
    for spec in lock_data.get("package", []):
        # spec: RequirementSpec
        k = (spec["name"], spec["version"], "__base__")
        pkg_deps = graph.setdefault(k, {})
        for dep in spec.get("dependencies", []):
            extras = dep.get("extra", ["__base__"])
            for e in extras:
                pkg_deps.setdefault((dep["name"], dep["version"], e), {})[dep.get("marker")] = 1

        for extra_name, optional_deps in spec.get("optional-dependencies", {}).items():
            ek = (spec["name"], spec["version"], extra_name)
            # Add a synthetic edge from the extra package to the base package
            pkg_deps = graph.setdefault(ek, {}).setdefault(k, {None: 1})
            for dep in optional_deps:
                extras = dep.get("extra", ["__base__"])
                for e in extras:
                    graph[ek].setdefault((dep["name"], dep["version"], e), {})[dep.get("marker")] = 1

    return graph

def _collect_sccs(graph):
    """Given the internal dependency graph, compute strongly connected
    components and the mapping from each dependency to the strongly connected
    component which contains that dependency.

    Returns:
     - A mapping from dependency to scc ID
     - A mapping from scc id to the dependencies which are members of the scc
     - A mapping from scc id to the dependencies which are directs of the scc

    """

    simplified_graph = {dep: nexts.keys() for dep, nexts in graph.items()}
    graph_components = sccs(simplified_graph)
    scc_graph = {
        sha1(repr(sorted(scc)))[:16]: scc
        for scc in graph_components
    }

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


def _extract_requirement_marker_pairs(req_string, version_map):
    """
    Parses a requirement string into a list of ((name, version, extra), marker) pairs.
    
    Args:
        req_string: The requirement string (e.g., "foo[bar]>=1.0; sys_platform == 'linux'").
        version_map: A dict mapping package names to default version strings.
        
    Returns:
        A list of tuples [((name, version, extra), marker), ...]. 
        The marker is a string or None.
    """
    # 1. Split Requirement and Marker
    # Starlark split() often doesn't support maxsplit, so we use find() + slicing
    semicolon_idx = req_string.find(";")
    
    marker = None
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
        " ": 1
    }
    
    name_end_idx = len(req_part)
    
    for i in range(len(req_part)):
        char = req_part[i]
        if char in stop_chars:
            name_end_idx = i
            break
    
    pkg_name = req_part[:name_end_idx]

    # 3. Extract Extras from req_part
    extras = []
    
    remainder = req_part[name_end_idx:]
    
    if remainder.startswith("["):
        close_idx = remainder.find("]")
        if close_idx != -1:
            content = remainder[1:close_idx]
            parts = content.split(",")
            for p in parts:
                clean_p = p.strip()
                if clean_p:
                    extras.append(clean_p)

    # 4. Look up version
    version = version_map.get(pkg_name)

    # 5. Construct results
    # Each result is ((name, ver, extra), marker)
    results = []
    
    # Base requirement
    base_dep = (pkg_name, version, "__base__")
    results.append((base_dep, marker))
    
    # Extras
    for e in extras:
        dep = (pkg_name, version, e)
        results.append((dep, marker))
        
    return results

def _collect_activated_extras(project_data, default_versions, graph):
    """
    Collect the set of extras which are directly or transitively activated in the given configuration.
    Assumes all marker expressions are live.

    Returns
      - {cfg: 1}
      - {dep: {cfg: {extra_dep: {marker: 1}}}}
    """

    dep_groups = project_data.get("dependency-groups", {
        project_data["project"]["name"]: [
            project_data["project"]["name"],
        ],
    })

    # Normalize dep groups to our dependency triples (graph keys)
    normalized_dep_groups = {}

    # Builds up {package: {configuration: {extra: {marker: 1}}}}
    activated_extras = {}

    for group_name, specs in dep_groups.items():
        normalized_dep_groups[group_name] = []
        for spec in specs:
            for dep, marker in _extract_requirement_marker_pairs(spec, default_versions):
                normalized_dep_groups[group_name].append(dep)

                # Note that this is the base case for the reach set walk below
                # We do this here so it's easy to handle marker expressions
                base = (dep[0], dep[1], "__base__")
                activated_extras.setdefault(base, {}).setdefault(group_name, {}).setdefault(dep, {}).update({marker: 1})

    for group_name, deps in normalized_dep_groups.items():
        worklist = list(deps)

        # Worklist graph traversal to handle the reach set
        visited = {}
        idx = 0
        for _ in range(2**31):
            if idx == len(worklist):
                break

            it = worklist[idx]
            visited[it] = 1

            for next, markers in graph.get(it, {}).items():
                # Convert `next`, being a dependency potentially with marker, to its base package
                base = (next[0], next[1], "__base__")
                # Upsert the base package so that under the appropriate cfg it lists next as a dep with the appropriate markers
                activated_extras.setdefault(base, {}).setdefault(group_name, {}).setdefault(next, {}).update(markers)
                if next not in visited:
                    visited[next] = 1
                    worklist.append(next)

            idx += 1

    return {it: 1 for it in dep_groups.keys()}, activated_extras

def _dump_cfg(activated_extras, cfg):
    """Convert an activation state to a `uv export`

    Specifically, this should match to

    ```
    $ uv export \\
       --format=requirements.txt \\
       --no-default-groups \\
       --no-hashes \\
       --no-annotate \\
       --only-group=$cfg
    ```

    For the given lockfile. Differences in comments and source/URL installed
    packages are expected.

    """
    lines = []
    for dep, cfgs in activated_extras.items():
        if cfg in cfgs:
            l = f"{dep[0]}=={dep[1]}"
            markers = cfgs[cfg][dep]
            marker_exprs = [it for it in markers.keys() if it is not None]
            if len(marker_exprs) > 1:
                marker_exprs = [f"({it})" for it in marker_exprs]
            marker_expr = ' or '.join(marker_exprs)
            if marker_expr and None not in markers:
                l = l + " ; " + marker_expr
            lines.append(l)
    return '\n'.join(sorted(lines, key = lambda l: l.split("==")[0]))

def _collate_versions_by_name(activated_extras):
    """
    Transforms the activated extras map into a mapping of names to configs to 
    versions to markers. This groups different versions of the same package 
    together under the package name.

    Returns:
      {name: {config: {version: {marker: 1}}}}
    """
    result = {}

    for (pkg_name, pkg_version, _), configs in activated_extras.items():
        for cfg, deps in configs.items():
            # Ensure path exists: result[name][cfg][version] -> {marker: 1}
            # We use setdefault chain to traverse/create the nested dicts
            version_markers = result.setdefault(pkg_name, {}).setdefault(cfg, {}).setdefault(pkg_version, {})

            # deps is {dep_triple: {marker: 1}}
            # We aggregate all markers for this version (from base and extras)
            # into the single map for this version string.
            for markers in deps.values():
                version_markers.update(markers)

    return result

def _collect_markers(graph):
    """
    Return a mapping of marker -> sha1, containing all markers in the graph
    """
    acc = {}
    for _dep, nexts in graph.items():
        for _next, markers in nexts.items():
            for marker in markers.keys():
                # sha1 is "expensive" so we minimize it
                if marker is not None and marker not in acc:
                    acc[marker] = sha1(marker)

    return acc

def _process_project(project_data, lock_data, hub_name="pypi"):
    """Build up the build graph components for implementing a given pyproject in
    Bazel according to the parameters of the lockfile.

    Arguments:
      project_data: the content of a pyproject.toml as a dict
      lock_data: the content of a uv.lock as a dict

    """
    
    # package_versions: {requirement: {version: 1}}  (set of versions per req.)
    # default_versions: {requirement: version}       the single version where only one
    package_versions, default_versions, lock_data = _normalize_deps(lock_data)
    graph = _build_marker_graph(lock_data)

    dep_to_scc, scc_members, scc_deps = _collect_sccs(graph)

    # This is also our hub keys
    # configuration_names: {cfg: 1}
    # activated_extras: {dep: {cfg: {extra: {marker: 1}}}}
    configuration_names, activated_extras = _collect_activated_extras(project_data, default_versions, graph)

    markers = _collect_markers(graph)

    version_activations = _collate_versions_by_name(activated_extras)

    pprint(version_activations)
    
if __name__ == "__main__":
    # pyproject.toml
    proj = sys.argv[1]
    # uv.lock
    lock = sys.argv[2]

    with open(proj, 'rb') as fp:
        proj_data = tomllib.load(fp)

    with open(lock, 'rb') as fp:
        lock_data = tomllib.load(fp)

    _process_project(proj_data, lock_data)
