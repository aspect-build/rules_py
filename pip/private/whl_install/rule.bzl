def _whl_install(ctx):
    pass


whl_install = rule(
    implementation = _whl_install,
    doc = """

""",
    attrs = {
        "srcs": attr.label_list(doc = ""),
    },
)
