"""
An implementation of fetching dependencies based on consuming UV's lockfiles.

Follows in the footsteps of rules_js's pnpm support by consuming a lockfile
which contains enough information to produce a virtualenv without performing any
dynamic resolution.

Relies on the lockfile to enumerate:
- Source distributions & their digests
- Prebuilt distribitons & their digests
- The dependencies of digests

## Example

    uv = use_repo("@aspect_rules_py//uv:extension.bzl", "uv")
    uv.declare_hub(hub_name = "uv")

    uv.declare_venv(hub_name = "uv", venv_name = "a")
    uv.lockfile(hub_name = "uv", venv_name = "a", lockfile = "third_party/py/venvs/uv-a.lock")

    uv.declare_venv(hub_name = "uv", venv_name = "b")
    uv.lockfile(hub_name = "uv", venv_name = "b", lockfile = "third_party/py/venvs/uv-b.lock")

    use_repo(uv, "uv")

## Features

- Supports cross-platform builds of wheels
- Supports hermetic source builds of wheels
- Automatically handles dependency cycles

## Appendix

[1] https://peps.python.org/pep-0751/
[2] https://peps.python.org/pep-0751/#locking-build-requirements-for-sdists
"""

"""
An implementation of fetching dependencies based on consuming UV's lockfiles.

This version implements version-explicit identities, stable SCC hashing, 
and project-based closures. It handles project-specific sdist builds and 
enforces mandatory overrides for virtual, path, and git dependencies.
"""

load("@bazel_features//:features.bzl", features = "bazel_features")
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")
load("//uv/private/constraints:repository.bzl", "configurations_hub")
load("//uv/private/hub:repository.bzl", "hub_repo")
load("//uv/private/sdist_build:repository.bzl", "sdist_build")
load("//uv/private/tomltool:toml.bzl", "toml")
load("//uv/private/venv_hub:repository.bzl", "venv_hub")
load("//uv/private/whl_install:repository.bzl", "whl_install")
load(":normalize_name.bzl", "normalize_name")
load(":parse_whl_name.bzl", "parse_whl_name")
load(":sccs.bzl", "sccs")
load(":sha1.bzl", "sha1")


def _pretty_print(val):
    """
    A worklist-based pretty printer for Starlark structs and collections.
    Uses a stack to perform depth-first traversal for a YAML-like format.
    """
    lines = []
    # Worklist acts as a stack: (value, indentation_level, optional_key)
    stack = [(val, 0, None)]

    for i in range(1000000):  # Starlark loop safety limit
        if not stack:
            break
        
        curr, indent, key = stack.pop()
        prefix = "  " * indent
        key_str = "{}: ".format(key) if key != None else ""
        
        t = type(curr)
        
        if t == "struct":
            lines.append("{}{}{}".format(prefix, key_str, ""))
            d = dir(curr)
            # Add to stack in reverse to process fields in correct order
            fields = sorted([f for f in d if f not in ("to_json", "to_proto")])
            for j in range(len(fields)):
                field = fields[len(fields) - 1 - j]
                stack.append((getattr(curr, field), indent + 1, field))
        
        elif t == "dict":
            lines.append("{}{}{}".format(prefix, key_str, ""))
            keys = curr.keys()
            for j in range(len(keys)):
                k = keys[len(keys) - 1 - j]
                stack.append((curr[k], indent + 1, str(k)))
        
        elif t == "list" or t == "tuple":
            lines.append("{}{}{}".format(prefix, key_str, ""))
            for j in range(len(curr)):
                item = curr[len(curr) - 1 - j]
                stack.append((item, indent + 1, "-"))
        
        else:
            # Leaf node
            lines.append("{}{}{}".format(prefix, key_str, curr))

    return "\n".join(lines)

# --- Identity Helpers ---

def _id(name, version, extra = ""):
    """Returns a structured identity triple (name, version, extra)."""
    return (name, version, extra)

# --- Repository Naming ---

def _norm_ver(version):
    """Normalizes a version string for use in repository names."""
    return version.replace(".", "_").replace("-", "_").replace("+", "_")

def _sdist_fetch_repo_name(name, version, sdist_hash):
    """Global fetch repo for an sdist (deduplicated by content)."""
    return "sdist__{}__{}__{}".format(
        name,
        _norm_ver(version),
        sdist_hash[len("sha256:"):len("sha256:") + 8],
    )

def _whl_fetch_repo_name(name, version, whl_hash):
    """Global fetch repo for a specific wheel (deduplicated by content)."""
    return "whl__{}__{}__{}".format(
        name,
        _norm_ver(version),
        whl_hash[len("sha256:"):len("sha256:") + 8],
    )

def _sbuild_repo_name(hub, project, name, version):
    """Build repo for an sdist, unique per project."""
    return "sbuild__{}__{}__{}_{}".format(hub, project, name, _norm_ver(version))

def _whl_install_repo_name(hub, project, name, version):
    """Install repo for a package version within a project context."""
    return "whl_install__{}__{}__{}_{}".format(
        hub,
        project,
        name,
        _norm_ver(version),
    )

def _venv_hub_name(hub, project, env):
    """Naming convention for the internal venv hub coordinator."""
    return "venv__{}__{}_{}".format(hub, project, env)

# --- Logic Pipeline ---

def _process_project_to_ir(hub_name, project_name, lock_data, pyproject_data):
    """
    Transforms a project's lock and metadata into a concrete, versioned IR.
    Computes closures for all dependency-groups defined in pyproject.toml.
    """
    packages = lock_data.get("package", [])
    nodes = {}
    name_to_versions = {}

    # Project's own name (to exempt from virtual override requirement)
    root_pkg_name = normalize_name(
        pyproject_data.get("project", {}).get("name", ""),
    )

    # 1. Identity & Implication Pass
    for pkg in packages:
        name = normalize_name(pkg["name"])
        ver = pkg["version"]
        p_id = _id(name, ver)

        # Check for mandatory override sources
        source = pkg.get("source", {})
        is_virtual = "virtual" in source
        is_path = "path" in source
        is_git = "git" in source

        # If it's one of these and NOT the root project itself, it needs override
        needs_override = (is_virtual or is_path or is_git) and (name != root_pkg_name)

        pkg["_needs_override"] = needs_override
        nodes[p_id] = pkg
        name_to_versions.setdefault(name, []).append(ver)

    implied = {
        name: vs[0]
        for name, vs in name_to_versions.items()
        if len(vs) == 1
    }

    # 2. Build Adjacency Graph (Base + Extras)
    graph = {}
    # edges: { from_id: { to_id: marker_expression } }
    edges = {}
    active_extras = {}  # pkg_id -> {extra_name: True}

    limit = len(nodes) * len(nodes)
    
    for p_id, pkg in nodes.items():
        graph[p_id] = []
        edges[p_id] = {}
        for dep in pkg.get("dependencies", []):
            d_name = normalize_name(dep["name"])
            d_ver = dep.get("version") or implied.get(d_name)
            d_id = _id(d_name, d_ver)
            marker = dep.get("marker", "")

            graph[p_id].append(d_id)
            edges[p_id][d_id] = marker

            for ex in dep.get("extra", []):
                ex_id = _id(d_name, d_ver, ex)
                graph[p_id].append(ex_id)
                edges[p_id][ex_id] = marker
                active_extras.setdefault(d_id, {})[ex] = True

    # 3. Transitive Extra Activation
    all_extra_ids = []
    for pid, exs in active_extras.items():
        for ex in exs.keys():
            all_extra_ids.append(_id(pid[0], pid[1], ex))

    for _ in range(limit):
        if not all_extra_ids:
            break
        
        ex_id = all_extra_ids.pop()

        if ex_id in graph:
            continue

        name, ver, extra_name = ex_id
        pkg = nodes[_id(name, ver)]
        opt_deps = pkg.get("optional-dependencies", {}).get(extra_name, [])

        graph[ex_id] = []
        edges[ex_id] = {}
        for o_dep in opt_deps:
            od_name = normalize_name(o_dep["name"])
            od_ver = o_dep.get("version") or implied.get(od_name)
            od_id = _id(od_name, od_ver)
            o_marker = o_dep.get("marker", "")

            graph[ex_id].append(od_id)
            edges[ex_id][od_id] = o_marker

            for o_ex in o_dep.get("extra", []):
                oe_id = _id(od_name, od_ver, o_ex)
                graph[ex_id].append(oe_id)
                edges[ex_id][oe_id] = o_marker
                if oe_id not in all_extra_ids:
                    all_extra_ids.append(oe_id)

    # 4. Stable SCC Computation
    print(_pretty_print(graph))
    raw_sccs = sccs(graph)
    node_to_scc = {}
    scc_metadata = {}
    print(_pretty_print(raw_sccs))
    for members in raw_sccs:
        # Hashing a list of tuples is stable in Starlark
        scc_id = "scc_" + sha1(str(sorted(members)))[:12]
        scc_metadata[scc_id] = struct(
            members = members,
            internal_edges = {},
            external_edges = {},
        )
        for m in members:
            node_to_scc[m] = scc_id

    # 5. SCC Boundary and Internal Edge Closures (with Markers)
    for sid, data in scc_metadata.items():
        for mid in data.members:
            member_edges = edges.get(mid, {})
            for neighbor, marker in member_edges.items():
                if node_to_scc[neighbor] == sid:
                    # Internal edge (part of the fat target cycle)
                    data.internal_edges.setdefault(mid, {})[neighbor] = marker
                else:
                    # External edge (transitive dependency of the fat target)
                    data.external_edges.setdefault(mid, {})[neighbor] = marker

    # 6. Environment Closures (Dependency Groups)
    envs = {}
    # Note that we hack in a default mapping from the project to itself
    groups = pyproject_data.get("dependency-groups", {root_pkg_name: [root_pkg_name]})
    for group_name, roots in groups.items():
        env_active = {}
        visited = {}
        worklist = []

        for r in roots:
            if ";" in r:
                fail("Group '{}' has root '{}' with a marker.".format(
                    group_name,
                    r,
                ))

            r_parts = r.split("[")
            r_name = r_parts[0]
            r_extras = r_parts[1][:-1].split(",") if len(r_parts) > 1 else []
            r_ver = implied.get(normalize_name(r_name))
            if r_ver:
                rid = _id(normalize_name(r_name), r_ver)
                worklist.append(rid)
                for rx in r_extras:
                    worklist.append(_id(rid[0], rid[1], rx))

        for _ in range(limit):
            if not worklist:
                break
            current = worklist.pop()
            if current in visited:
                continue
            visited[current] = True
            sid = node_to_scc[current]
            req_name = current[0]
            env_active.setdefault(req_name, {})[sid] = True
            for neighbor in graph.get(current, []):
                worklist.append(neighbor)

        envs[group_name] = {k: sorted(v.keys()) for k, v in env_active.items()}

    return struct(
        nodes = nodes,
        node_to_scc = node_to_scc,
        scc_metadata = scc_metadata,
        environments = envs,
        implied = implied,
    )

def _gather_context(module_ctx):
    """Parses all TOML files and tags into a flat context for IR generation."""
    projects = []
    annotations = {}  # hub -> project -> name -> data
    overrides = {}  # hub -> project -> name -> target

    for mod in module_ctx.modules:
        for proj in mod.tags.project:
            projects.append(struct(
                hub_name = proj.hub_name,
                name = proj.name,
                lock_data = toml.decode_file(module_ctx, proj.lock),
                pyproject_data = toml.decode_file(module_ctx, proj.pyproject),
            ))

        for ann in mod.tags.unstable_annotate_requirements:
            annotations.setdefault(ann.hub_name, {}).setdefault(ann.project_name, {})
            content = toml.decode_file(module_ctx, ann.src)
            for pkg in content.get("package", []):
                name = normalize_name(pkg["name"])
                annotations[ann.hub_name][ann.project_name][name] = pkg

        for ovr in mod.tags.override_requirement:
            overrides.setdefault(ovr.hub_name, {}).setdefault(ovr.project_name, {})
            name = normalize_name(ovr.requirement)
            overrides[ovr.hub_name][ovr.project_name][name] = str(ovr.target)

    return struct(
        projects = projects,
        annotations = annotations,
        overrides = overrides,
    )

def _generate_manifest(ctx):
    """Functional helper that generates all repository specifications."""
    manifest = struct(
        fetch_repos = {},
        build_repos = {},
        install_repos = {},
        project_hubs = [],
        markers = {},  # shasum -> marker_expression
    )

    def _intern_marker(marker):
        if not marker:
            return ""
        m_sha = sha1(marker)[:8]
        manifest.markers[m_sha] = marker
        return m_sha

    for proj in ctx.projects:
        ir = _process_project_to_ir(
            proj.hub_name,
            proj.name,
            proj.lock_data,
            proj.pyproject_data,
        )

        proj_anns = ctx.annotations.get(proj.hub_name, {}).get(proj.name, {})
        proj_ovrs = ctx.overrides.get(proj.hub_name, {}).get(proj.name, {})

        # Intern all markers in the SCC metadata
        for scc_data in ir.scc_metadata.values():
            for src_id, dst_map in scc_data.internal_edges.items():
                for dst_id, marker in dst_map.items():
                    dst_map[dst_id] = _intern_marker(marker)
            for src_id, dst_map in scc_data.external_edges.items():
                for dst_id, marker in dst_map.items():
                    dst_map[dst_id] = _intern_marker(marker)

        for p_id, pkg in ir.nodes.items():
            name, ver, _ = p_id

            if pkg["_needs_override"] and name not in proj_ovrs:
                fail("Package '{}' in project '{}' needs an override.".format(
                    name,
                    proj.name,
                ))

            if name in proj_ovrs:
                continue

            # A. Fetch Repos
            sdist = pkg.get("sdist")
            sfetch_name = None
            if sdist:
                url = sdist.get("url", pkg["source"].get("url"))
                shasum = sdist["hash"][len("sha256:"):]
                sfetch_name = _sdist_fetch_repo_name(name, ver, sdist["hash"])
                manifest.fetch_repos[sfetch_name] = dict(
                    name = sfetch_name,
                    urls = [url],
                    sha256 = shasum,
                    downloaded_file_path = url.split("/")[-1],
                )

            for whl in pkg.get("wheels", []):
                url = whl["url"]
                shasum = whl["hash"][len("sha256:"):]
                wfetch_name = _whl_fetch_repo_name(name, ver, whl["hash"])
                manifest.fetch_repos[wfetch_name] = dict(
                    name = wfetch_name,
                    urls = [url],
                    sha256 = shasum,
                    downloaded_file_path = url.split("/")[-1],
                )

            # B. Build Repos
            sbuild_name = None
            if sdist:
                sbuild_name = _sbuild_repo_name(proj.hub_name, proj.name, name, ver)
                ann = proj_anns.get(name, {})
                build_deps = [
                    dict(name = "build"),
                    dict(name = "setuptools"),
                ] + ann.get("build-dependencies", [])

                resolved_deps = []
                for bd in build_deps:
                    bd_name = normalize_name(bd["name"])
                    if bd_name in proj_ovrs:
                        resolved_deps.append(proj_ovrs[bd_name])
                    else:
                        bd_ver = ir.implied.get(bd_name)
                        if bd_ver:
                            target = _whl_install_repo_name(
                                proj.hub_name,
                                proj.name,
                                bd_name,
                                bd_ver,
                            )
                            resolved_deps.append("@" + target + "//:lib")

                manifest.build_repos[sbuild_name] = struct(
                    name = sbuild_name,
                    src = "@" + sfetch_name + "//file",
                    deps = resolved_deps,
                    is_native = ann.get("native", False),
                )

            # C. Install Repos
            install_name = _whl_install_repo_name(proj.hub_name, proj.name, name, ver)
            prebuilds = {}
            for whl in pkg.get("wheels", []):
                key = whl["url"].split("/")[-1]
                val = "@" + _whl_fetch_repo_name(name, ver, whl["hash"]) + "//file"
                prebuilds[key] = val

            manifest.install_repos[install_name] = struct(
                name = install_name,
                prebuilds = prebuilds,
                sbuild = "@" + sbuild_name + "//:whl" if sbuild_name else None,
            )

        # D. Hub targets mapping
        target_map = {}
        for node_id in ir.node_to_scc.keys():
            n_name, n_ver, _ = node_id
            if n_name in proj_ovrs:
                target_map[str(node_id)] = proj_ovrs[n_name]
            else:
                target = _whl_install_repo_name(
                    proj.hub_name,
                    proj.name,
                    n_name,
                    n_ver,
                )
                target_map[str(node_id)] = "@" + target + "//:lib"

        for env_name, env_manifest in ir.environments.items():
            manifest.project_hubs.append(struct(
                name = _venv_hub_name(proj.hub_name, proj.name, env_name),
                manifest = env_manifest,
                sccs = ir.scc_metadata,
                targets = target_map,
            ))

    return manifest

def _uv_impl(module_ctx):
    """Main entrypoint for the extension."""
    ctx = _gather_context(module_ctx)
    manifest = _generate_manifest(ctx)

    print(_pretty_print(manifest))

    # Final Execution Pass (Side Effects)
    # for spec in manifest.fetch_repos.values():
    #     http_file(**spec)

    # for spec in manifest.build_repos.values():
    #     sdist_build(
    #         name = spec.name,
    #         src = spec.src,
    #         deps = spec.deps,
    #         is_native = spec.is_native,
    #     )

    # for spec in manifest.install_repos.values():
    #     whl_install(
    #         name = spec.name,
    #         prebuilds = spec.prebuilds,
    #         sbuild = spec.sbuild,
    #     )

    # for spec in manifest.project_hubs:
    #     venv_hub(
    #         name = spec.name,
    #         manifest = spec.manifest,
    #         sccs = spec.sccs,
    #         targets = spec.targets,
    #         markers = json.encode(manifest.markers),
    #     )

    # if features.external_deps.extension_metadata_has_reproducible:
    #     return module_ctx.extension_metadata(reproducible = True)

    fail("Not ready yet")
    
# --- Tag Definitions ---

_hub_attrs = {
    "hub_name": attr.string(mandatory = True),
}

_project_attrs = {
    "hub_name": attr.string(mandatory = True),
    "name": attr.string(mandatory = True),
    "lock": attr.label(mandatory = True),
    "pyproject": attr.label(mandatory = True),
}

_annotate_attrs = {
    "hub_name": attr.string(mandatory = True),
    "project_name": attr.string(mandatory = True),
    "src": attr.label(mandatory = True),
}

_override_attrs = {
    "hub_name": attr.string(mandatory = True),
    "project_name": attr.string(mandatory = True),
    "requirement": attr.string(mandatory = True),
    "target": attr.label(mandatory = True),
}

uv = module_extension(
    implementation = _uv_impl,
    tag_classes = {
        "declare_hub": tag_class(attrs = _hub_attrs),
        "project": tag_class(attrs = _project_attrs),
        "unstable_annotate_requirements": tag_class(attrs = _annotate_attrs),
        "override_requirement": tag_class(attrs = _override_attrs),
    },
)

