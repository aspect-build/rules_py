"""
Extension bridging to the host_platform_repo.

Required under bzlmod so that we can evaluate host-dependent configuration
defaults.
"""

load("@bazel_features//:features.bzl", features = "bazel_features")
load(":repository.bzl", "host_platform_repo")

def _host_platform_impl(module_ctx):
    host_platform_repo(name = "aspect_rules_py_uv_host")

    if not features.external_deps.extension_metadata_has_reproducible:
        return None
    return module_ctx.extension_metadata(reproducible = True)

host_platform = module_extension(
    implementation = _host_platform_impl,
    doc = """Generates a <code>host_platform_repo</code> repo named
<code>host_platform</code>, containing constraints for the host platform.""",
)
