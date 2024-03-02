"Module Extensions used from MODULE.bazel"

load(":repositories.bzl", "DEFAULT_TOOLS_REPOSITORY", "rules_py_toolchains")
load("//tools:version.bzl", "IS_PRERELEASE")

py_toolchain = tag_class(attrs = {
    "name": attr.string(doc = """\
Base name for generated repositories, allowing more than one toolchain to be registered.
Overriding the default is only permitted in the root module.
""", default = DEFAULT_TOOLS_REPOSITORY),
    "is_prerelease": attr.bool(
        doc = "True iff there are no pre-built tool binaries for this version of rules_py",
        default = IS_PRERELEASE,
    ),
})

def _toolchains_extension_impl(module_ctx):
    registrations = {}
    for mod in module_ctx.modules:
        for toolchain in mod.tags.rules_py_tools:
            if toolchain.name != DEFAULT_TOOLS_REPOSITORY and not mod.is_root:
                fail("""\
                Only the root module may override the default name for the rules_py_tools toolchain.
                This prevents conflicting registrations in the global namespace of external repos.
                """)
            registrations[toolchain.name] = toolchain.is_prerelease
    for name, is_prerelease in registrations.items():
        rules_py_toolchains(name, register = False, is_prerelease = is_prerelease)

py_tools = module_extension(
    implementation = _toolchains_extension_impl,
    tag_classes = {"rules_py_tools": py_toolchain},
)
