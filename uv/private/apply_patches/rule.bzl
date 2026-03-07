"""Rule for applying patches to a tree artifact.

Used as a post-install step to patch installed Python packages before they are
exposed as py_library targets.
"""

load("//uv/private/diffutils:defs.bzl", "PATCH_TOOL_LABEL")

def _apply_patches(ctx):
    src = ctx.attr.src[DefaultInfo].files.to_list()[0]
    out = ctx.actions.declare_directory(ctx.attr.out_dir)

    patch_tool = ctx.file._patch_tool
    patch_files = [f for t in ctx.attr.patches for f in t[DefaultInfo].files.to_list()]

    args = [
        patch_tool.path,
        str(ctx.attr.patch_strip),
        src.path,
        out.path,
    ] + [f.path for f in patch_files]

    ctx.actions.run(
        executable = ctx.file._apply_script,
        arguments = args,
        inputs = [src, patch_tool] + patch_files,
        outputs = [out],
        mnemonic = "ApplyPatches",
        progress_message = "Applying %d patch(es) to %s" % (len(patch_files), ctx.label.name),
        use_default_shell_env = True,
    )

    return [
        DefaultInfo(
            files = depset([out]),
            runfiles = ctx.runfiles(files = [out]),
        ),
    ]

apply_patches = rule(
    implementation = _apply_patches,
    doc = """Copies a tree artifact and applies patch files to the copy.

Used to apply post-install patches to installed Python packages.""",
    attrs = {
        "src": attr.label(
            mandatory = True,
            doc = "The source tree artifact to patch.",
        ),
        "patches": attr.label_list(
            mandatory = True,
            allow_files = [".patch", ".diff"],
            doc = "Patch files to apply in order.",
        ),
        "patch_strip": attr.int(
            default = 0,
            doc = "The number of leading path segments to strip from patch file paths (-p flag).",
        ),
        "out_dir": attr.string(
            mandatory = True,
            doc = "Name for the output directory.",
        ),
        "_patch_tool": attr.label(
            default = PATCH_TOOL_LABEL,
            allow_single_file = True,
            cfg = "exec",
        ),
        "_apply_script": attr.label(
            default = "//uv/private/apply_patches:apply_patches.sh",
            allow_single_file = True,
        ),
    },
)
