"""

Generate a cluster of config_settings which bridge from well-known static config
features (interpreter feature flags, interpreter version, platform, etc.) to the
dynamic(ish) set of Python platform "triples" defined by the lockfile.

This bridging allows wheel selection to occur in Python-native terms according
to just the Python platform triple which is defined elsewhere/centrally (here),
and makes debugging easier as well as the generated selections more meaningful.

"""

load("@bazel_features//:features.bzl", features = "bazel_features")

def _format_list(items):
    return "[\n" + "".join(["    {},\n".format(repr(it)) for it in items]) + "]"

def _constraints_hub_impl(repository_ctx):
    """Generates a repository of `config_setting` targets.

    This rule materializes platform "triple" `config_setting` targets into a
    central repository, which are then used by other rules to implement
    platform-specific logic: for each entry in the `configurations` attribute,
    it creates a `config_setting_group` that represents a specific Python
    platform (e.g., a combination of interpreter, platform, and ABI like
    `cp39-manylinux_2_17_x86_64-cp39`). These are used by `whl_install`
    to select the correct pre-built wheel.

    Args:
        repository_ctx: The repository context.
    """

    ################################################################################
    content = [
        "load(\"@bazel_skylib//lib:selects.bzl\", \"selects\")",
    ]

    for name, conditions in repository_ctx.attr.configurations.items():
        # FIXME: Set visibility narrowly? Would have to be to all the hubs and
        # all the wheels, feels like a lot of work.
        content.append(
            """
selects.config_setting_group(
    name = "{}",
    match_all = {},
    visibility = ["//visibility:public"],
)
""".format(name, _format_list(conditions)),
        )

    content.append("""
exports_files(
    ["BUILD.bazel"],
    visibility = ["//visibility:public"],
)
""")

    repository_ctx.file("BUILD.bazel", content = "\n".join(content))

    if not features.external_deps.extension_metadata_has_reproducible:
        return None
    return repository_ctx.repo_metadata(reproducible = True)

configurations_hub = repository_rule(
    implementation = _constraints_hub_impl,
    attrs = {
        "configurations": attr.string_list_dict(),
    },
)
