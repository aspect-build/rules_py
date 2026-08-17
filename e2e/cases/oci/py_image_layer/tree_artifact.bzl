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
