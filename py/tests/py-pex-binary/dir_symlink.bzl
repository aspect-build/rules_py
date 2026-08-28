"""Fixture: a directory symlink next to the tree artifact it targets."""

def _dir_and_symlink_impl(ctx):
    tree = ctx.actions.declare_directory(ctx.label.name + "_dir")
    ctx.actions.run_shell(
        outputs = [tree],
        arguments = [tree.path],
        command = 'mkdir -p "$1/sub" && printf dir-symlink-payload > "$1/payload.txt" && printf nested-payload > "$1/sub/nested.txt"',
    )
    link = ctx.actions.declare_symlink(ctx.label.name + "_link")
    ctx.actions.symlink(output = link, target_path = ctx.label.name + "_dir")
    files = depset([tree, link])
    return [DefaultInfo(files = files, runfiles = ctx.runfiles(transitive_files = files))]

dir_and_symlink = rule(
    doc = "A tree artifact plus a relative directory symlink pointing at it.",
    implementation = _dir_and_symlink_impl,
)
