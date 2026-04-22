"""bzlmod module extension for rules_py toolchains.

This module declares ``py_tools``, a ``module_extension`` consumed from
``MODULE.bazel`` via ``rules_py_tools`` tags. It orchestrates the creation of
external repositories that contain the pre-built native tools (unpacker, pth
builder, etc.) needed by the Python toolchain.

Known problems:
    - Dead import: ``TELEMETRY`` is loaded from ``@aspect_tools_telemetry_report``
      but never referenced in this file. It should be removed or used.
    - The two-pass logic (accumulate non-root names, then filter against
      ``root_name``) is unnecessary; the root could be handled in a single pass.
    - The module-level docstring was historically vacuous (only "Module Extensions
      used from MODULE.bazel"), giving no hint about the root-only name policy.
"""

load("@aspect_tools_telemetry_report//:defs.bzl", "TELEMETRY")
load("//py/private/release:version.bzl", "IS_PRERELEASE")
load(":toolchains.bzl", "DEFAULT_TOOLS_REPOSITORY", "rules_py_toolchains")

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

py_tools = module_extension(
    implementation = _toolchains_extension_impl,
    tag_classes = {"rules_py_tools": py_toolchain},
)
