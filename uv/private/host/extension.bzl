"""
Extension bridging to the host_platform_repo.

Required under bzlmod so that we can evaluate host-dependent configuration
defaults.
"""

load(":repository.bzl", "host_platform_repo")

def _host_platform_impl(module_ctx):
    host_platform_repo(name = "aspect_rules_py_uv_host")

    # module_ctx.extension_metadata has the parameter `reproducible` as of Bazel 7.1.0. We can't
    # test for it directly and would ideally use bazel_features to check for it, but adding a
    # dependency on it would require complicating the WORKSPACE setup. Thus, test for it by
    # checking the availability of another feature introduced in 7.1.0.
    if hasattr(module_ctx, "extension_metadata") and hasattr(module_ctx, "watch"):
        return module_ctx.extension_metadata(reproducible = True)
    else:
        return None

host_platform = module_extension(
    implementation = _host_platform_impl,
    doc = """Generates a <code>host_platform_repo</code> repo named
<code>host_platform</code>, containing constraints for the host platform.""",
)
