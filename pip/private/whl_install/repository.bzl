
def _whl_install_impl(repository_ctx):

    config = json.decode(repository_ctx.attr.config)

    aliases = [
        "alias(name = '{}', actual = '@{}//file')".format(name, spec["name"])
        for name, spec in config.items()
    ]

    repository_ctx.file("BUILD.bazel", content = "\n".join(aliases))


whl_install = repository_rule(
    implementation = _whl_install_impl,
    attrs = {
        "deps": attr.label_list(),
    },
)
