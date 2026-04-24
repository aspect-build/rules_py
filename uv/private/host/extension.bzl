"""bzlmod extension that instantiates the host-platform repository.

This allows host-dependent configuration defaults to be evaluated under
bzlmod without requiring a WORKSPACE-based setup.
"""

load("@bazel_features//:features.bzl", features = "bazel_features")
load(":repository.bzl", "host_platform_repo")

def _host_platform_impl(module_ctx):
    """Create the host platform repository and declare reproducibility.

    Bazel 7.1.0 introduced `extension_metadata(reproducible = True)`.  To avoid
    adding a dependency on `bazel_features`, we detect support heuristically by
    checking for `extension_metadata` together with `watch`, both added in the
    same release.

    Args:
      module_ctx: the module extension context.

    Returns:
      The result of `module_ctx.extension_metadata(reproducible = True)` when
      supported, otherwise `None`.
    """
    host_platform_repo(name = "aspect_rules_py_uv_host")

    if not features.external_deps.extension_metadata_has_reproducible:
        return None
    return module_ctx.extension_metadata(reproducible = True)

host_platform = module_extension(
    implementation = _host_platform_impl,
    doc = """Generates a host_platform_repo named `aspect_rules_py_uv_host`.

The generated repository contains host-platform constraints that can be
consumed by other build logic to select compatible prebuilt artifacts.
""",
)
