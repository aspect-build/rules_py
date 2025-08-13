def _venv_hub_impl(repository_ctx):
    print(repository_ctx.attrs)

venv_hub = repository_rule(
    implementation = _venv_hub_impl,
    attrs = {
        "packages": attr.string_dict(
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
