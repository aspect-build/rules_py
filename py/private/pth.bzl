"""Helper functions for creating Python .pth files and building imports depsets."""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@rules_python//python:defs.bzl", "PyInfo")

def _make_import_path(label, workspace, imp):
    if imp.startswith("/"):
        fail(
            "Import path '{imp}' on target {target} is invalid. Absolute paths are not supported.".format(
                imp = imp,
                target = str(label),
            ),
        )

    base_segments = label.package.split("/")
    path_segments = imp.split("/")

    relative_segments = 0
    for segment in path_segments:
        if segment == "..":
            relative_segments += 1
        else:
            break

    if relative_segments == (len(base_segments) + 1):
        fail(
            "Import path '{imp}' on target {target} is invalid. Import paths must not escape the workspace root".format(
                imp = imp,
                target = str(label),
            ),
        )

    if imp.startswith(".."):
        return paths.normalize(paths.join(workspace, *(base_segments[0:-relative_segments] + path_segments[relative_segments:])))
    else:
        return paths.normalize(paths.join(workspace, label.package, imp))

def make_imports_depset(deps, imports, workspace_name, label = None, extra_imports_depsets = []):
    """Build an imports depset from PyInfo providers and explicit import paths.

    Args:
        deps: List of targets that provide PyInfo. Their transitive imports are merged.
        imports: List of explicit import path strings. Relative paths (e.g. "..")
            are resolved against the label's package if label is provided.
        workspace_name: The workspace name to include for repo-relative imports.
        label: Optional label used to resolve relative import paths.
        extra_imports_depsets: Additional depsets of imports to merge.

    Returns:
        A depset of import path strings.
    """
    if label:
        import_paths = [
            _make_import_path(label, label.workspace_name or workspace_name, im)
            for im in imports
        ]
    else:
        import_paths = list(imports)

    # Add the workspace name in the imports such that repo-relative imports work.
    import_paths.append(workspace_name)

    # Handle the case where its a target from an external workspace that uses repo-relative imports
    if label and label.workspace_name:
        import_paths.append(label.workspace_name)

    return depset(
        direct = import_paths,
        transitive = [
            target[PyInfo].imports
            for target in deps
            if PyInfo in target
        ] + extra_imports_depsets,
    )

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
