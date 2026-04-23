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

    dep_to_scc = json.decode(repository_ctx.attr.dep_to_scc)
    scc_deps = json.decode(repository_ctx.attr.scc_deps)
    scc_graph = json.decode(repository_ctx.attr.scc_graph)

    installs = {}
    for scc_installs in scc_graph.values():
        for install in scc_installs:
            installs[install] = 1

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

    venv_content = []

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
        "@aspect_rules_py//uv/private/constraints/venv:venv": "{name}",
    }},
    visibility = ["//visibility:public"],
)
""".format(name = cfg_name),
        )
    repository_ctx.file("private/venv/BUILD.bazel", content = "\n".join(venv_content))

    content = ["""\
load("@aspect_rules_py//py:defs.bzl", "py_library")

"""]
    for package, cfgs in dep_to_scc.items():
        content.append("""
# {}
{}
""".format(package, indent(pprint(cfgs), "# ")))
        main_arms = {}

        # FIXME: Handle markers for distinct versions
        for cfg, scc_cfgs in cfgs.items():
            cfg_name = "_package_{}_{}".format(package, cfg)
            main_arms["//private/venv:" + cfg] = ":" + cfg_name

            cfg_arms = {}

            for scc, markers in scc_cfgs.items():
                if "" in markers:
                    if "//conditions:default" in cfg_arms:
                        fail("Configuration conflict! Package {} specifies two or more default package states!\n{}".format(package, pprint(cfgs)))

                    cfg_arms["//conditions:default"] = "//private/sccs:" + scc

                else:
                    for marker in markers.keys():
                        marker = _marker(marker)
                        if marker in cfg_arms:
                            fail("Configuration conflict! Package {} specifies two or more configurations for the same marker!\n{}".format(package, pprint(cfgs)))

                        cfg_arms[marker] = "//private/sccs:" + scc

            content.append("""
alias(
    name = "{name}",
    actual = select({arms}),
    visibility = ["//visibility:private"],
)
""".format(name = cfg_name, arms = indent(pprint(cfg_arms), " " * 4).lstrip()))

        if len(main_arms) == 1:
            main_arms["//conditions:default"] = list(main_arms.values())[0]

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

    all_requirements = {}
    for package, cfgs in dep_to_scc.items():
        for cfg in cfgs.keys():
            all_requirements.setdefault("//private/venv:" + cfg, []).append("//:" + package)

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
""".format(
        arms = indent(pprint(all_requirements), " " * 4).lstrip(),
        gazelle_whls = indent(pprint([it.replace("//:install", "//:gazelle_index_whl") for it in installs]), " " * 4).lstrip(),
    ))

    repository_ctx.file("BUILD.bazel", "\n".join(content))

    content = ["""\
load("@aspect_rules_py//py:defs.bzl", "py_library")

# A dummy target so we can select to nothing when no markers match.
py_library(
    name = "empty",
    srcs = [],
    deps = [],
    imports = [],
    visibility = ["//visibility:private"],
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

    repository_ctx.file("private/sccs/BUILD.bazel", "\n".join(content))

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

    repository_ctx.file("private/markers/BUILD.bazel", "\n".join(content))

uv_project = repository_rule(
    implementation = _project_impl,
    attrs = {
        "dep_to_scc": attr.string(),
        "scc_deps": attr.string(),
        "scc_graph": attr.string(),
    },
)
