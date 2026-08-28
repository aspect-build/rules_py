"""Fixtures for TreeArtifact coverage in py_image_layer tests."""

def _tree_artifact_impl(ctx):
    output = ctx.actions.declare_directory(ctx.label.name + "_tree")
    direct = ctx.actions.declare_file(ctx.label.name + "_direct.txt")
    ctx.actions.run_shell(
        outputs = [output, direct],
        arguments = [output.path, direct.path],
        command = "mkdir -p \"$1\" && printf tree-artifact > \"$1/tree_payload.txt\" && printf tree-artifact-space > \"$1/tree payload.txt\" && printf direct-artifact > \"$2\"",
    )
    return [DefaultInfo(files = depset([output, direct]))]

tree_artifact = rule(implementation = _tree_artifact_impl)

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

def _relative_symlink_impl(ctx):
    link = ctx.actions.declare_symlink(ctx.label.name)
    ctx.actions.symlink(output = link, target_path = ctx.attr.target_path)
    return [DefaultInfo(files = depset([link]))]

relative_symlink = rule(
    doc = "A declared symlink with an authored relative target path.",
    implementation = _relative_symlink_impl,
    attrs = {"target_path": attr.string(mandatory = True)},
)

def _symlink_target_impl(ctx):
    output = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(output, "symlink target\n")
    return [DefaultInfo(files = depset([output]))]

symlink_target = rule(implementation = _symlink_target_impl)

def _symlink_to_target_impl(ctx):
    output = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(output = output, target_file = ctx.file.target)
    return [DefaultInfo(files = depset([output]))]

symlink_to_target = rule(
    implementation = _symlink_to_target_impl,
    attrs = {"target": attr.label(allow_single_file = True, mandatory = True)},
)
