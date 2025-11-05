"""

"""

def _venv_hub_impl(repository_ctx):
    # Lay down an alias from every nominal package to the scc containing it.
    #
    # TODO: If packages had markers, those markers would have to go here.

    entrypoints = json.decode(repository_ctx.attr.entrypoints)

    for pkg, group in repository_ctx.attr.aliases.items():
        content = []
        content.append(
            """
alias(
   name = "lib",
   actual = "//private/sccs:{scc}",
   visibility = ["//visibility:public"],
)
alias(
   name = "{pkg}",
   actual = "//private/sccs:{scc}",
   visibility = ["//visibility:public"],
)
""".format(
                pkg = pkg,
                scc = group,
            ),
        )
        repository_ctx.file("{}/BUILD.bazel".format(pkg), content = "\n".join(content))

        content = [
            """load("@aspect_rules_py//uv/private/py_entrypoint_binary:defs.bzl", "py_entrypoint_binary")""",
        ]
        for entrypoint_name, entrypoint_coordinate in entrypoints.get(pkg, {}).items():
            content.append(
                """
py_entrypoint_binary(
    name = "{name}",
    deps = ["//{pkg}:{pkg}"],
    coordinate = "{coordinate}",
    visibility = ["//visibility:public"],
)
""".format(
                    name = entrypoint_name,
                    pkg = pkg,
                    coordinate = entrypoint_coordinate,
                ),
            )

        repository_ctx.file("{}/entrypoints/BUILD.bazel".format(pkg), content = "\n".join(content))

    # Lay down a package full of marker conditions which we'll reuse as we
    # evaluate the groups' dependencies.
    content = [
        "# FIXME",
        """load("@aspect_rules_py//uv/private/markers:defs.bzl", "decide_marker")""",
    ]
    for name, marker in repository_ctx.attr.markers.items():
        content.append(
            """
decide_marker(
    name = "{name}",
    marker = "{marker}",
    visibility = ["//private:__subpackages__"],
)
""".format(
                name = name,
                marker = marker,
            ),
        )

    repository_ctx.file("private/markers/BUILD.bazel", content = "\n".join(content))

    # So the strategy here is that we need to go through sccs, create each scc
    # and depend on the members of the scc by their _install_ directly rather
    # than by their alias/group.
    #
    # Deps are added to the scc group by their _alias_.

    # JSON decode the marker mapping so we can use it
    scc_markers = json.decode(repository_ctx.attr.scc_markers)
    print(scc_markers)

    content = [
        "# FIXME",
        """load("@aspect_rules_py//py:defs.bzl", "py_library")""",
        "load(\"@bazel_skylib//lib:selects.bzl\", \"selects\")",
        """
# A placeholder library which allows us to select to nothing
py_library(
    name = "empty",
    srcs = [],
    imports = [],
    visibility = ["//visibility:private"]
)
""",
    ]

    for group, members in repository_ctx.attr.sccs.items():
        member_installs = [
            "\"@{}//:install\"".format(repository_ctx.attr.installs[it])
            for it in members
        ]

        deps = repository_ctx.attr.deps[group]
        if group not in scc_markers:
            1 + []

        dep_labels = []
        for d in deps:
            if d in members:
                # Easy case of dependency edges within the group
                continue

            markers = scc_markers[group].get(d, [])
            if not markers:
                # Easy case of non-conditional external dep
                dep_labels.append("\"//%s\"" % d)

            else:
                print("Got markers", markers)

                # Hard case of generating a conditional dep
                content.append(
                    """
# All of the markers under which {group} depends on {d}
selects.config_setting_group(
    name = "_maybe_{group}_{d}",
    match_any = {markers},
    visibility = ["//visibility:private"],
)

# Depend on {d} of any of the {group} markers is active
alias(
    name = "_{group}_{d}",
    actual = select({{
        ":_maybe_{group}_{d}": "//{d}",
        "//conditions:default": ":empty",
    }}),
)
""".format(
                        group = group,
                        d = d,
                        markers = ["//private/markers:%s" % it for it in markers],
                    ),
                )
                dep_labels.append("\":_{}_{}\"".format(group, d))

        content.append(
            """
py_library(
   name = "{}",
   srcs = [],
   deps = [
{}
   ],
   visibility = ["//:__subpackages__"],
)
""".format(
                group,
                ",\n".join([((" " * 8) + it) for it in (member_installs + dep_labels)]),
            ),
        )

    repository_ctx.file("private/sccs/BUILD.bazel", content = "\n".join(content))

venv_hub = repository_rule(
    implementation = _venv_hub_impl,
    attrs = {
        "aliases": attr.string_dict(
            doc = """
            """,
        ),
        "markers": attr.string_dict(
            doc = """
            """,
        ),
        "sccs": attr.string_list_dict(
            doc = """
            """,
        ),
        "scc_markers": attr.string(
            doc = """
            Graph of pkg -> dep -> Option[marker ID]
            """,
        ),
        "deps": attr.string_list_dict(
            doc = """
            """,
        ),
        "installs": attr.string_dict(
            doc = """
            """,
        ),
        "entrypoints": attr.string(
            doc = """
        JSON encoded map of pkg -> entrypoint -> coordinate
        """,
        ),
    },
    doc = """
Create a hub repository containing all the package(s) for all configuration(s) of a venv.

TODO: Need to figure out where compatibility selection lives in here.
""",
)
