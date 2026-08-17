"""Opaque runtime-wrapper fixture: exposes only a marker file through
DefaultInfo.files while carrying the `data` targets' full runfiles (no PyInfo)."""

def _runtime_wrapper_impl(ctx):
    marker = ctx.actions.declare_file(ctx.label.name + "_marker.txt")
    ctx.actions.write(marker, "runtime wrapper marker\n")
    runfiles = ctx.runfiles(files = [marker])
    for dep in ctx.attr.data:
        runfiles = runfiles.merge(ctx.runfiles(transitive_files = dep[DefaultInfo].files))
        runfiles = runfiles.merge(dep[DefaultInfo].default_runfiles)
    return [DefaultInfo(files = depset([marker]), default_runfiles = runfiles)]

runtime_wrapper = rule(
    implementation = _runtime_wrapper_impl,
    attrs = {"data": attr.label_list()},
)
