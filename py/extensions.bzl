"""bzlmod module extensions for rules_py.

This module exports two module extensions:

- ``py_tools``: Provisions pre-built native tools (unpacker, pth builder, etc.)
  needed by the Python toolchain.

- ``python_interpreters``: Provisions Python interpreters from
  python-build-standalone (PBS) releases with automatic version resolution
  and cross-platform support.
"""

load("@aspect_tools_telemetry_report//:defs.bzl", "TELEMETRY")  # buildifier: disable=load
load("@bazel_features//:features.bzl", features = "bazel_features")
load("@aspect_tools_telemetry_report//:defs.bzl", "TELEMETRY")
load("//py/private/interpreter:extension.bzl", _python_interpreters = "python_interpreters")
load("//py/private/release:version.bzl", "IS_PRERELEASE")
load(":toolchains.bzl", "DEFAULT_TOOLS_REPOSITORY", "rules_py_toolchains")

python_interpreters = _python_interpreters

py_toolchain = tag_class(attrs = {
    "name": attr.string(
        doc = """\
Base name for generated repositories, allowing more than one toolchain to be registered.
Overriding the default is only permitted in the root module.
""",
        default = DEFAULT_TOOLS_REPOSITORY,
    ),
    "is_prerelease": attr.bool(
        doc = "True iff there are no pre-built tool binaries for this version of rules_py",
        default = IS_PRERELEASE,
    ),
})

def _toolchains_extension_impl(module_ctx):
    """Create toolchain repositories for every module that declares a tag.

    Iterates over the dependency graph and enforces two policies:

    1. **Root-only name override** — Only the root module may change the
       repository name from ``DEFAULT_TOOLS_REPOSITORY``. Non-root modules that
       attempt to do so trigger a fatal error to prevent namespace collisions.
    2. **Root wins** — When the root module declares a tag, its settings take
       precedence. Dependent modules that use the default name are ignored to
       avoid redundant repository creation.

    Args:
        module_ctx: The module extension context provided by Bazel.
    """
    registrations = []
    root_name = None
    for mod in module_ctx.modules:
        for toolchain in mod.tags.rules_py_tools:
            if toolchain.name != DEFAULT_TOOLS_REPOSITORY and not mod.is_root:
                fail("""\
                Only the root module may override the default name for the rules_py_tools toolchain.
                This prevents conflicting registrations in the global namespace of external repos.
                """)

            if mod.is_root:
                rules_py_toolchains(toolchain.name, register = False, is_prerelease = toolchain.is_prerelease)
                root_name = toolchain.name
            else:
                registrations.append(toolchain.name)

    for name in registrations:
        if name != root_name:
            rules_py_toolchains(name, register = False)

    if not features.external_deps.extension_metadata_has_reproducible:
        return None
    return module_ctx.extension_metadata(reproducible = True)

py_tools = module_extension(
    implementation = _toolchains_extension_impl,
    tag_classes = {"rules_py_tools": py_toolchain},
)
