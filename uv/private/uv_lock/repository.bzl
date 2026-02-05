"""

"""

load("//uv/private:pprint.bzl", "pprint")
load("//uv/private:sha1.bzl", "sha1")

def indent(text, space = " "):
    return "\n".join(["{}{}".format(space, l) for l in text.splitlines()])

def _venv_hub_impl(repository_ctx):
    dep_to_scc = json.decode(repository_ctx.attr.dep_to_scc)
    scc_deps = json.decode(repository_ctx.attr.scc_deps)
    scc_graph = json.decode(repository_ctx.attr.scc_graph)

    ################################################################################
    # First the easy bit -- lay down the scc aliases
    content = []
    for name, scc_id in dep_to_scc.items():
        content.append("""
alias(
    name = "{name}",
    actual = "//private/sccs:{scc}",
    visibility = ["//visibility:public"],
)
""".format(name = name, scc = scc_id))
    repository_ctx.file("BUILD.bazel", "\n".join(content))

    ################################################################################

    repository_ctx.file("private/BUILD.bazel", """\
load("@aspect_rules_py//py:defs.bzl", "py_library")

py_library(
    name = "empty",
    srcs = [],
    deps = [],
    imports =  [],
    visibility = ["//:__subpackages__"],
)
""")

    ################################################################################
    # Now the slightly harder bit -- lay down the SCCs

    # As we go for simplicity we collect markers
    marker_table = {}

    content = ["""\
load("@aspect_rules_py//py:defs.bzl", "py_library")

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
        for member, markers in list(members.items()) + list(this_scc_deps.items()):
            # FIXME: Hack. Why do we have names coming in like this?
            if member[0] == ":":
                member = "//" + member

            if "" in markers:
                # This is a dep which can be reached unconditionally
                # Add it directly
                deps.append(member)

            else:
                # This is a dep which is conditional
                cases = {}
                for marker in markers.keys():
                    # We know that "" cannot be in the markers from above
                    if marker not in marker_table:
                        marker_table[marker] = sha1(marker)
                    marker_id = marker_table[marker]

                    cases["//private/markers:" + marker_id] = member
                cases["//conditions:default"] = "//private:empty"

                dep = "_maybe__{}__{}".format(scc_id, sha1(member)[:16])
                deps.append(dep)
                content.append("""
alias(
    name = "{name}",
    actual = select({arms}),
    visibility = ["//:__subpackages__"],
)
""".format(
                    name = dep,
                    arms = indent(pprint(cases), "    ").lstrip(),
                ))

        content.append("""
py_library(
    name = "{name}",
    deps = {deps},
    visibility = ["//:__subpackages__"],
)
""".format(
            name = scc_id,
            deps = indent(pprint(deps), "    ").lstrip(),
        ))

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

    repository_ctx.file("private/markers/BUILD.bazel", "\n".join(content))

uv_lock = repository_rule(
    implementation = _venv_hub_impl,
    attrs = {
        "dep_to_scc": attr.string(
            doc = """
            """,
        ),
        "scc_deps": attr.string(
            doc = """
            """,
        ),
        "scc_graph": attr.string(
            doc = """
            """,
        ),
    },
    doc = """
Create a hub repository containing all the package(s) for all configuration(s) of a venv.

TODO: Need to figure out where compatibility selection lives in here.
""",
)
