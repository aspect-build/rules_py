"""

"""

load("@bazel_features//:features.bzl", features = "bazel_features")
load("//uv/private:sha1.bzl", "sha1")
load("//uv/private/pprint:defs.bzl", "pprint")

def indent(text, space = " "):
    return "\n".join(["{}{}".format(space, l) for l in text.splitlines()])

def name(quad):
    _lock, package_name, package_version, package_extra = quad.split(",")
    if package_extra == "__base__":
        return "{}__{}".format(package_name, package_version)
    else:
        return "{}__{}__extra__{}".format(package_name, package_version, package_extra)

def _project_impl(repository_ctx):
    """Materializes the dependency graph for a single project.

    Attrs:
        dep_to_scc:   {package: {cfg: {scc: {marker: 1}}}}
        scc_deps:     {scc: {package: {marker: 1}}}
        scc_graph:    {scc: {install: {marker: 1}}}
    """

    # Styleguide; string append via `+=` is inefficient. Prefer to use a list as
    # a pseudo string builder buffer and a single final "\n".join(content) to
    # materialize the buffer to a final writable string.

    # Styleguide: Address each layer of aliases sequentially. Each layer should
    # begin with a comment explaining what faimily of BUILD.bazel files will be
    # generated, and end with the required `repository_ctx.file(path, content)`
    # call.

    # These are provided as JSON strings and must be decoded.
    dep_to_scc = json.decode(repository_ctx.attr.dep_to_scc)
    scc_deps = json.decode(repository_ctx.attr.scc_deps)
    scc_graph = json.decode(repository_ctx.attr.scc_graph)

    # Collect all the underlying whl installs
    installs = {}
    for scc_installs in scc_graph.values():
        for install in scc_installs:
            installs[install] = 1

    # As we go for simplicity we collect markers
    marker_table = {}

    def _marker(expr):
        """
        Given a marker expression, get a label for it.
        Interns the marker expression into the marker table as needed.
        """
        if expr not in marker_table:
            marker_table[expr] = sha1(expr)
        marker_id = marker_table[expr]
        return "//private/markers:" + marker_id

    def _conditionalize(it, markers, cond_id_thunk, no_match = None):
        if "" in markers:
            return it
        else:
            # This is a dep which is conditional
            cases = {}
            for marker in markers.keys():
                cases[_marker(marker)] = it

            if no_match:
                cases["//conditions:default"] = no_match

            cond_id = cond_id_thunk()
            content.append("""
alias(
    name = "{name}",
    actual = select({arms}),
    visibility = ["//:__subpackages__"],
)
""".format(
                name = cond_id,
                arms = indent(pprint(cases), " " * 4).lstrip(),
            ))
            return ":" + cond_id

    ################################################################################
    # Lay down the //private/dep_group:BUILD.bazel file with config flags
    #
    # This mirrors the uv_hub's dep_group, but is internal to the project.
    venv_content = []

    # Collect all unique cfgs first
    all_cfgs = set()
    for dep, cfgs in dep_to_scc.items():
        for cfg in cfgs.keys():
            all_cfgs.add(cfg)

    for cfg_name in all_cfgs:
        venv_content.append(
            """
config_setting(
    name = "{name}",
    flag_values = {{
        "@aspect_rules_py//uv/private/constraints/dep_group:dep_group": "{name}",
    }},
    visibility = ["//visibility:public"],
)
""".format(name = cfg_name),
        )
    repository_ctx.file("private/dep_group/BUILD.bazel", content = "\n".join(venv_content))

    ################################################################################
    # Lay down the surface-level targets
    content = ["""\
load("@aspect_rules_py//py:defs.bzl", "py_library")

# Fallback for `:{package}_whl` aliases on workspace / editable packages
# (which have no underlying whl_install repo to point at).
filegroup(
    name = "empty_whl",
    srcs = [],
    visibility = ["//visibility:public"],
)

"""]
    for package, cfgs in dep_to_scc.items():
        content.append("""
# {}
{}
""".format(package, indent(pprint(cfgs), "# ")))
        main_arms = {}
        whl_main_arms = {}

        # FIXME: Handle markers for distinct versions
        for cfg, scc_cfgs in cfgs.items():
            cfg_name = "_package_{}_{}".format(package, cfg)
            main_arms["//private/dep_group:" + cfg] = ":" + cfg_name

            whl_cfg_name = "_package_{}_{}_whl".format(package, cfg)

            cfg_arms = {}
            whl_cfg_arms = {}

            # This is a bit tricky. We're doing choice between several different
            # SCCs possibly encoding different versions or extra specializations
            # of a package "at once" depending on the venv + marker set.
            # Consequently this second-level choice is actually the MERGE
            # between the individual cases under which specific markers evaluate
            # to true. It's a configuration and locking failure for there to be
            # more than one package which resolves at this point. So we just jam all the configurations into a single select.
            for scc, markers in scc_cfgs.items():
                # Find the whl install for `package` within this SCC's members.
                # The repo label encodes the package name (e.g.
                # @whl_install__{stamp}__{name}__{ver}//:install), so we match
                # by substring with `__{package}__`. Workspace / editable
                # packages have no whl_install and yield None.
                whl_for_pkg = None
                for install_label in scc_graph.get(scc, {}).keys():
                    if ("__" + package + "__") in install_label:
                        whl_for_pkg = install_label.replace(":install", ":whl")
                        break

                if "" in markers:
                    if "//conditions:default" in cfg_arms:
                        fail("Configuration conflict! Package {} specifies two or more default package states!\n{}".format(package, pprint(cfgs)))

                    cfg_arms["//conditions:default"] = "//private/sccs:" + scc
                    if whl_for_pkg:
                        whl_cfg_arms["//conditions:default"] = whl_for_pkg

                else:
                    for marker in markers.keys():
                        marker = _marker(marker)
                        if marker in cfg_arms:
                            fail("Configuration conflict! Package {} specifies two or more configurations for the same marker!\n{}".format(package, pprint(cfgs)))

                        cfg_arms[marker] = "//private/sccs:" + scc
                        if whl_for_pkg:
                            whl_cfg_arms[marker] = whl_for_pkg

            # Marker-only SCCs need an inactive value when no marker matches.
            if "//conditions:default" not in cfg_arms:
                cfg_arms["//conditions:default"] = "//private/sccs:empty"

            # Now we can just build one big choice alias from that arm set.
            content.append("""
alias(
    name = "{name}",
    actual = select({arms}),
    visibility = ["//visibility:private"],
)
""".format(name = cfg_name, arms = indent(pprint(cfg_arms), " " * 4).lstrip()))

            # Parallel whl-file alias. Workspace/editable packages have no
            # whl_install, and marker-only wheels may be inactive. In either
            # case the fallback is a filegroup with no srcs.
            if "//conditions:default" not in whl_cfg_arms:
                whl_cfg_arms["//conditions:default"] = ":empty_whl"
            whl_main_arms["//private/dep_group:" + cfg] = ":" + whl_cfg_name
            content.append("""
alias(
    name = "{name}",
    actual = select({arms}),
    visibility = ["//visibility:private"],
)
""".format(name = whl_cfg_name, arms = indent(pprint(whl_cfg_arms), " " * 4).lstrip()))

        # Finally we can render the wrapper over all the component arms
        content.append("""
alias(
    name = "{name}",
    actual = select({arms}),
    visibility = ["//visibility:public"],
)
""".format(
            name = package,
            arms = indent(pprint(main_arms), " " * 4).lstrip(),
        ))

        content.append("""
alias(
    name = "{name}",
    actual = select({arms}),
    visibility = ["//visibility:public"],
)
""".format(
            name = package + "_whl",
            arms = indent(pprint(whl_main_arms), " " * 4).lstrip(),
        ))

    # As part of this root repo we also lay down :all_requirements which is slightly tricky because we have to
    all_requirements = {}
    for package, cfgs in dep_to_scc.items():
        for cfg in cfgs.keys():
            all_requirements.setdefault("//private/dep_group:" + cfg, []).append("//:" + package)

    content.append("""
filegroup(
    name = "all_requirements",
    srcs = select({arms}),
    visibility = ["//visibility:public"],
)
filegroup(
    name = "gazelle_index_whls",
    srcs = {gazelle_whls},
    visibility = ["//visibility:public"],
)

exports_files(
    ["BUILD.bazel"],
    visibility = ["//visibility:public"],
)
""".format(
        arms = indent(pprint(all_requirements), " " * 4).lstrip(),
        gazelle_whls = indent(pprint([it.replace("//:install", "//:gazelle_index_whl") for it in installs]), " " * 4).lstrip(),
    ))

    repository_ctx.file("BUILD.bazel", "\n".join(content))

    ################################0################################################
    # Now the slightly harder bit -- lay down the SCCs

    content = ["""\
load("@aspect_rules_py//py:defs.bzl", "py_library")

# A dummy target so we can select to nothing when no markers match.
py_library(
    name = "empty",
    srcs = [],
    deps = [],
    imports = [],
    # Generated package aliases in the parent package select this target.
    visibility = ["//:__pkg__"],
)
"""]

    for scc_id, members in scc_graph.items():
        this_scc_deps = scc_deps.get(scc_id, {})
        deps = []
        content.append("""
# scc: {}
# members:
{}
# deps:
{}
""".format(scc_id, indent(pprint(members), "# "), indent(pprint(this_scc_deps), "# ")))

        for member, markers in members.items():
            deps.append(_conditionalize(
                member,
                markers,
                lambda: "_maybe__{}__{}".format(scc_id, sha1(member)[:16]),
                no_match = ":empty",
            ))

        for dep, markers in this_scc_deps.items():
            deps.append(_conditionalize(
                # Note that we map these back to surface packages
                "//:" + dep,
                markers,
                lambda: "_maybe__{}__{}".format(scc_id, sha1(dep)[:16]),
                no_match = ":empty",
            ))

        content.append("""
py_library(
    name = "{name}",
    deps = {deps},
    visibility = ["//:__subpackages__"],
)
""".format(
            name = scc_id,
            deps = indent(pprint(deps), " " * 4).lstrip(),
        ))

    content.append("""
exports_files(
    ["BUILD.bazel"],
    visibility = ["//visibility:public"],
)
""")

    repository_ctx.file("private/sccs/BUILD.bazel", "\n".join(content))

    ################################################################################
    # Finally lay down the collected markers
    content = ["""
load("@aspect_rules_py//uv/private/markers:defs.bzl", "decide_marker")

"""]

    for marker_expr, marker_id in marker_table.items():
        content.append("""
decide_marker(
    name = "{name}",
    marker = {marker},
    visibility = ["//:__subpackages__"],
)
""".format(name = marker_id, marker = repr(marker_expr)))

    content.append("""
exports_files(
    ["BUILD.bazel"],
    visibility = ["//visibility:public"],
)
""")

    repository_ctx.file("private/markers/BUILD.bazel", "\n".join(content))

    if not features.external_deps.extension_metadata_has_reproducible:
        return None
    return repository_ctx.repo_metadata(reproducible = True)

uv_project = repository_rule(
    implementation = _project_impl,
    attrs = {
        "dep_to_scc": attr.string(),
        "scc_deps": attr.string(),
        "scc_graph": attr.string(),
    },
)
