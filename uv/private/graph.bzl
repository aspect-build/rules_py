"""
A library for processing uv lockfiles into dependency graphs.
"""

load(":normalize_name.bzl", "normalize_name")
load(":sccs.bzl", "sccs")
load(":sha1.bzl", "sha1")

def _normalize_deps(lock_data):
    """
    Normalize the lockfile.
    1. Compute the "default version" mapping
    2. Update all the dependency statements within the lockfile so they're version disambiguated
    """

    package_versions = {}
    for spec in lock_data.get("package", []):
        package_versions.setdefault(spec["name"], {})[spec["version"]] = 1

    default_versions = {
        requirement: versions.keys()[0]
        for requirement, versions in package_versions.items() if len(versions.keys()) == 1
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

def _dep_to_key(name, version, extra):
    return "{}@{}|{}".format(name, version, extra)

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
        k = _dep_to_key(spec["name"], spec["version"], "__base__")
        pkg_deps = graph.setdefault(k, {})
        for dep in spec.get("dependencies", []):
            extras = dep.get("extra", ["__base__"])
            for e in extras:
                dep_key = _dep_to_key(dep["name"], dep["version"], e)
                pkg_deps.setdefault(dep_key, {})[dep.get("marker")] = 1

        for extra_name, optional_deps in spec.get("optional-dependencies", {}).items():
            ek = _dep_to_key(spec["name"], spec["version"], extra_name)
            # Add a synthetic edge from the extra package to the base package
            graph.setdefault(ek, {})[k] = {None: 1}
            for dep in optional_deps:
                extras = dep.get("extra", ["__base__"])
                for e in extras:
                    dep_key = _dep_to_key(dep["name"], dep["version"], e)
                    graph[ek].setdefault(dep_key, {})[dep.get("marker")] = 1

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
        sha1(repr(sorted(scc))): scc
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
    semicolon_idx = req_string.find(";")
    
    marker = None
    if semicolon_idx != -1:
        marker_text = req_string[semicolon_idx + 1:].strip()
        if marker_text:
            marker = marker_text
        req_part = req_string[:semicolon_idx].strip()
    else:
        req_part = req_string.strip()

    if not req_part:
        return []

    # 2. Identify end of package name
    stop_chars = "[=><!~ "
    
    name_end_idx = len(req_part)
    for i in range(len(req_part)):
        if req_part[i] in stop_chars:
            name_end_idx = i
            break
    
    pkg_name = req_part[:name_end_idx]

    # 3. Extract Extras
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
    results = []
    
    # Base requirement
    results.append(((pkg_name, version, "__base__"), marker))
    
    # Extras
    for e in extras:
        results.append(((pkg_name, version, e), marker))
        
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

    normalized_dep_groups = {}
    activated_extras = {}

    for group_name, specs in dep_groups.items():
        normalized_dep_groups[group_name] = []
        for spec in specs:
            for dep, marker in _extract_requirement_marker_pairs(spec, default_versions):
                normalized_dep_groups[group_name].append(dep)

                base = (dep[0], dep[1], "__base__")
                activated_extras.setdefault(base, {}).setdefault(group_name, {}).setdefault(dep, {}).update({marker: 1})

    for group_name, deps in normalized_dep_groups.items():
        worklist = list(deps)
        visited = {dep: True for dep in deps}

        while worklist:
            it = worklist.pop(0)

            for next_dep_tuple, markers in graph.get(_dep_to_key(*it), {}).items():
                # next_dep_tuple is a string key, need to parse it back
                name, rest = next_dep_tuple.split('@', 1)
                version, extra = rest.split('|', 1)
                next_dep = (name, version, extra)

                if not visited.get(next_dep, False):
                    visited[next_dep] = True
                    worklist.append(next_dep)
                
                base = (next_dep[0], next_dep[1], "__base__")
                activated_extras.setdefault(base, {}).setdefault(group_name, {}).setdefault(next_dep, {}).update(markers)


    return dep_groups.keys(), activated_extras

def process_project(module_ctx, project_tag, project_data, lock_data):
    """
    Build up the build graph components for implementing a given pyproject in
    Bazel according to the parameters of the lockfile.

    Args:
        module_ctx: The module context.
        project_tag: The project tag containing hub_name, name, pyproject, and lock.
        project_data: The content of a pyproject.toml as a dict.
        lock_data: The content of a uv.lock as a dict.
    """
    package_versions, default_versions, lock_data = _normalize_deps(lock_data)
    graph = _build_marker_graph(lock_data)
    dep_to_scc, scc_members, scc_deps = _collect_sccs(graph)
                    return {
        "hub_name": project_tag.hub_name,
        "project_name": project_tag.name,
        "lock_data": lock_data,
        "dep_to_scc": dep_to_scc,
        "scc_members": scc_members,
        "scc_deps": scc_deps,
        "configuration_names": configuration_names,
        "activated_extras": activated_extras,
    }