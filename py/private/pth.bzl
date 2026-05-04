"""Helper functions for creating Python .pth files."""

def write_pth_file(ctx, name, imports_depset, escape = None):
    """Create a .pth file from an imports depset.

    Args:
        ctx: The rule context.
        name: Base name for the output file (`{name}.pth`).
        imports_depset: A depset of strings containing import paths.
        escape: Optional prefix to prepend to each import path. Also written as
            the first line of the file. For py_binary-style rules, this should be
            the relative path from site-packages to the runfiles root.

    Returns:
        The declared File for the .pth file.
    """
    pth_lines = ctx.actions.args()
    pth_lines.use_param_file("%s", use_always = True)
    pth_lines.set_param_file_format("multiline")

    if escape:
        pth_lines.add(escape)
        pth_lines.add_all(imports_depset, format_each = "{}/%s".format(escape))
    else:
        pth_lines.add_all(imports_depset)

    pth_file = ctx.actions.declare_file("{}.pth".format(name))
    ctx.actions.write(
        output = pth_file,
        content = pth_lines,
    )
    return pth_file
