"Module Extensions used from MODULE.bazel"

load("//tools:version.bzl", "IS_PRERELEASE")
load(":toolchains.bzl", "DEFAULT_TOOLS_REPOSITORY", "rules_py_toolchains")

py_toolchain = tag_class(attrs = {
    "name": attr.string(doc = """\
Base name for generated repositories, allowing more than one toolchain to be registered.
Overriding the default is only permitted in the root module.
""", default = DEFAULT_TOOLS_REPOSITORY),
    "is_prerelease": attr.bool(
        doc = "True iff there are no pre-built tool binaries for this version of rules_py",
        default = IS_PRERELEASE,
    ),
    "rules_py_tools_version": attr.string(doc = "When not using a prerelease, overrides the version of tools fetched from GH releases"),
})

def _toolchains_extension_impl(module_ctx):
    registrations = []
    root_name = None
    for mod in module_ctx.modules:
        for toolchain in mod.tags.rules_py_tools:
            if toolchain.name != DEFAULT_TOOLS_REPOSITORY and not mod.is_root:
                fail("""\
                Only the root module may override the default name for the rules_py_tools toolchain.
                This prevents conflicting registrations in the global namespace of external repos.
                """)

            # Ensure the root wins in case of differences
            if mod.is_root:
                rules_py_toolchains(toolchain.name, register = False, is_prerelease = toolchain.is_prerelease, rules_py_tools_version = toolchain.rules_py_tools_version)
                root_name = toolchain.name
            else:
                registrations.append(toolchain.name)
    for name in registrations:
        if name != root_name:
            rules_py_toolchains(name, register = False)

py_tools = module_extension(
    implementation = _toolchains_extension_impl,
    tag_classes = {"rules_py_tools": py_toolchain},
)
