
def _pip_hub_impl(repository_ctx):

    config = json.decode(repository_ctx.attr.config)

    aliases = [
        "alias(name = '{}', actual = '@{}//file')".format(name, spec["name"])
        for name, spec in config.items()
    ]

    repository_ctx.file("BUILD.bazel", content = "\n".join(aliases))


pip_hub = repository_rule(
    implementation = _pip_hub_impl,
    attrs = {
        "config": attr.string(),
    },
)
