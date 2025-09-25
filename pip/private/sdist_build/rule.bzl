def _sdist_build(ctx):
    pass

sdist_build = rule(
    implementation = _sdist_build,
    doc = """

""",
    attrs = {
        "srcs": attr.label_list(doc = ""),
        "deps": attr.label_list(doc = ""),
    },
)
