"""Control repositories for test.sh: one cacheable, one never cacheable."""

def _cache_probe_impl(repository_ctx):
    repository_ctx.file("BUILD.bazel", 'exports_files(["probe"])\n')
    repository_ctx.file("probe", repository_ctx.original_name)
    if repository_ctx.attr.reproducible:
        return repository_ctx.repo_metadata(reproducible = True)
    return None

cache_probe = repository_rule(
    implementation = _cache_probe_impl,
    attrs = {"reproducible": attr.bool(mandatory = True)},
)
