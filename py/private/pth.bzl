"""Helper functions for creating Python .pth files and building imports depsets."""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("//py/private:py_info.bzl", "PyInfo")

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

    This helper merges transitive imports from `deps` and resolves any relative
    `imports` against the target's package. It also automatically appends the
    workspace root so that repo-relative imports work:

    - The current `workspace_name` is always appended.
    - If `label` is provided and it originates from an external workspace,
      `label.workspace_name` is appended as well.

    This means callers do not need to manually add the workspace root.

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

    import_paths.append(workspace_name)

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

    A `.pth` file is dropped into the venv's `site-packages` directory so that
    the interpreter adds those directories to `sys.path` at startup.

    When `escape` is provided, it is prepended to every import path and also
    written as the first line of the file. This is used by `py_binary` because
    the `.pth` file lives deep inside the venv tree, e.g.:

        {name}.runfiles/.{name}.venv/lib/python{version}/site-packages/{name}.pth

    The `escape` value is the relative path from `site-packages` back to the
    runfiles root (e.g. `../../../../..`). By writing it as the first line, the
    runfiles root itself becomes importable, which is required by a few targets
    (notably `@bazel_tools//tools/python/runfiles`) that rely on the root being on
    `sys.path` but have no `imports` attribute to hint that they need it.

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
