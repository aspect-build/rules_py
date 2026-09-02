load("//uv/private/pprint:defs.bzl", "indent", "pprint")
load("//uv/private/uv_project:build_deps.bzl", "write_build_deps")
load("//uv/private/uv_project:select_gen.bzl", "EMPTY_LIBRARY", "build_package_select_arms", "conditional_dep", "marker_interner", "safe_name", "write_markers")

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
    build_deps = json.decode(repository_ctx.attr.build_deps_json) if repository_ctx.attr.build_deps_json else None

    # Collect all the underlying whl installs
    installs = {}
    for scc_installs in scc_graph.values():
        for install in scc_installs:
            installs[install] = 1

    # As we go for simplicity we collect markers
    marker_table = {}
    _marker = marker_interner(marker_table)

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

            cfg_arms, whl_cfg_arms = build_package_select_arms(
                scc_cfgs = scc_cfgs,
                scc_graph = scc_graph,
                package = package,
                marker_fn = _marker,
            )

            content.append("""
alias(
    name = "{name}",
    actual = select({arms}),
    visibility = ["//visibility:private"],
)
""".format(name = cfg_name, arms = indent(pprint(cfg_arms), " " * 4).lstrip()))
            whl_main_arms["//private/dep_group:" + cfg] = ":" + whl_cfg_name
            content.append("""
alias(
    name = "{name}",
    actual = select({arms}),
    visibility = ["//visibility:private"],
)
""".format(name = whl_cfg_name, arms = indent(pprint(whl_cfg_arms), " " * 4).lstrip()))

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

    content.append("""
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
        gazelle_whls = indent(pprint([it.replace("//:install", "//:whl") for it in installs]), " " * 4).lstrip(),
    ))

    repository_ctx.file("BUILD.bazel", "\n".join(content))
    if repository_ctx.attr.available_deps_json:
        repository_ctx.file("available_deps.json", repository_ctx.attr.available_deps_json)
    if repository_ctx.attr.build_deps_json:
        repository_ctx.file("build_deps.json", repository_ctx.attr.build_deps_json)

    ################################0################################################
    # Now the slightly harder bit -- lay down the SCCs

    content = [EMPTY_LIBRARY]

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
            deps.append(conditional_dep(content, member, markers, "_maybe__{}__{}".format(scc_id, safe_name(member)), _marker, ":empty"))

        # SCC deps are mapped back to surface packages
        for dep, markers in this_scc_deps.items():
            deps.append(conditional_dep(content, "//:" + dep, markers, "_maybe__{}__{}".format(scc_id, safe_name(dep)), _marker, ":empty"))

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
    # Build requirements have their own graph, independent of runtime groups.
    if build_deps != None:
        write_build_deps(repository_ctx, build_deps["packages"], build_deps["scc_graph"], marker_fn = _marker)

    ################################################################################
    # Finally lay down the collected markers
    write_markers(repository_ctx, marker_table)

    return repository_ctx.repo_metadata(reproducible = True)

uv_project = repository_rule(
    implementation = _project_impl,
    attrs = {
        "available_deps_json": attr.string(),
        "build_deps_json": attr.string(),
        "dep_to_scc": attr.string(),
        "scc_deps": attr.string(),
        "scc_graph": attr.string(),
    },
)
