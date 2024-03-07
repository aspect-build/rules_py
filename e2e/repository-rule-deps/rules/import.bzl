load("@bazel_skylib//lib:paths.bzl", "paths")

def _myrepo_impl(repository_ctx):
    p = repository_ctx.workspace_root.get_child(repository_ctx.attr.path)
    find_cmd = ["find", str(p), "-maxdepth", "1", "-mindepth", "1"]
    r = repository_ctx.execute(find_cmd)
    if r.return_code != 0:
        fail(r.stdout + "\n" + r.stderr)

    files = r.stdout.splitlines()
    for f in files:
        repository_ctx.symlink(f, paths.basename(f))

    r = repository_ctx.execute(find_cmd)
    if r.return_code != 0:
        fail(r.stdout + "\n" + r.stderr)

myrepo = repository_rule(
    implementation = _myrepo_impl,
    attrs = {
        "path": attr.string(mandatory = True),
    },
)

def _importer_impl(module_ctx):
    myrepo(name = "myrepo", path = "imported")

importer = module_extension(
    implementation = _importer_impl,
)
