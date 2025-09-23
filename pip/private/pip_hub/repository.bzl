
def _pip_hub_impl(repository_ctx):

    content = [
        "# FIXME",
    ]

    # Lay down the venv config settings
    for name in repository_ctx.attr.venvs:
        content.append(
"""
config_setting(
   name = "{0}",
   flag_values = {{
       "//virtualenv:virtualenv": "{0}",
   }},
)
""".format(name)
    )
    repository_ctx.file("virtualenv/BUILD.bazel", content = "\n".join(content))

    content = [
        "# FIXME ",
    ]

    # Lay down the hub aliases
    for name, spec in repository_ctx.attr.packages.items():
        select_spec = {
            "//virtualenv:{}".format(it): "@venv__{}__{}//:{}".format(repository_ctx.attr.hub_name, it, name)
            for it in spec
        }
        content.append(
"""
alias(
    name = "{}",
    actual = select(
      {},
      no_match_error = "FIXME",
    ),
)
""".format(name, repr(select_spec))
        )

    repository_ctx.file("package/BUILD.bazel", content = "\n".join(content))


pip_hub = repository_rule(
    implementation = _pip_hub_impl,
    attrs = {
        "hub_name": attr.string(),
        "venvs": attr.string_list(),
        "packages": attr.string_list_dict(),
    },
)
