"""Root-module configuration independent of interpreter provisioning.

See docs/python-version-project-scope.md for setup and ownership requirements.
"""

def _config_repo_impl(rctx):
    if rctx.attr.python_version_scope == "project" and native.bazel_version:
        version = native.bazel_version.split(".")
        if (int(version[0]), int(version[1])) < (9, 2):
            fail("Python version project scope requires Bazel 9.2 or later")
    rctx.file("BUILD.bazel", 'exports_files(["config.bzl"])\n')
    rctx.file("config.bzl", "PYTHON_VERSION_SCOPE = %r\n" % rctx.attr.python_version_scope)

_config_repo = repository_rule(
    implementation = _config_repo_impl,
    configure = True,
    attrs = {"python_version_scope": attr.string()},
)

def _config_impl(module_ctx):
    scope = ""
    configured = False
    for mod in module_ctx.modules:
        for tag in mod.tags.python_version_scope:
            if not mod.is_root:
                continue
            if configured:
                fail("python_version_scope may only be configured once")
            configured = True
            scope = tag.scope
    _config_repo(name = "aspect_rules_py_config", python_version_scope = scope)
    return module_ctx.extension_metadata(reproducible = True)

python_config = module_extension(
    doc = """Global configuration for rules_py, independent of interpreter provisioning.

Only the root module may opt into Python version project scoping; dependency
module tags are ignored. The root
`//:PROJECT.scl` defines which targets retain version transitions. Unowned targets
reset to the invocation's baseline. Omitting the tag preserves existing behavior.
""",
    implementation = _config_impl,
    tag_classes = {
        "python_version_scope": tag_class(attrs = {
            "scope": attr.string(mandatory = True, values = ["universal", "project"]),
        }),
    },
)
