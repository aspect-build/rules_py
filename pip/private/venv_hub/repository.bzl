def _venv_hub_impl(repository_ctx):
    print("venv_hub", repository_ctx.attr)

    content = [
        "# FIXME",
    ]

    for name, group in repository_ctx.attr.aliases.items():
        content.append(
"""
alias(
   name = "{}",
   actual = "//:{}",
)
""".format(name, group)
        )

    # So the strategy here is that we need to go through sccs, create each scc
    # and depend on the members of the scc by their _install_ directly rather
    # than by their alias/group.
    #
    # Deps are added to the scc group by their _alias_.
    for group, members in repository_ctx.attr.sccs.items():
        member_installs = ["        \"@{}//:install\",".format(repository_ctx.attr.installs[it]) for it in members]
        deps = [
            "        \":{}\",".format(it)
            for it in repository_ctx.attr.deps[group]
        ]
        content.append(
"""
filegroup(
   name = "{}",
   srcs = [
       {}
   ],
)
""".format(
    group,
    "\n".join(member_installs + deps),
))

    repository_ctx.file("BUILD.bazel", content = "\n".join(content))

venv_hub = repository_rule(
    implementation = _venv_hub_impl,
    attrs = {
        "aliases": attr.string_dict(
            doc = """
            """,
        ),
        "sccs": attr.string_list_dict(
            doc = """
            """,
        ),
        "deps": attr.string_list_dict(
            doc = """
            """,
        ),
        "installs": attr.string_dict(
            doc = """
            """
        ),
    },
    doc = """
Create a hub repository containing all the package(s) for all configuration(s) of a venv.

TODO: Need to figure out where compatability selection lives in here.
"""
)
