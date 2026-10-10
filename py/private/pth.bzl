"""Helper functions for building imports depsets."""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("//py/private:py_info_interop.bzl", "get_import_dirs", "get_py_info", "has_py_info")

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

def own_import_paths(imports, workspace_name, label = None):
    """The import roots a target contributes itself, ahead of its deps'.

    Relative `imports` resolve against the label's package, and the workspace
    root is always appended (plus the label's own repository root when it's
    external), so repo-relative imports work.

    Args:
        imports: List of explicit import path strings. Relative paths (e.g. "..")
            are resolved against the label's package if label is provided.
        workspace_name: The workspace name to include for repo-relative imports.
        label: Optional label used to resolve relative import paths.

    Returns:
        A list of runfiles-root-relative import path strings.
    """
    if label:
        import_paths = [
            _make_import_path(label, label.repo_name or workspace_name, im)
            for im in imports
        ]
    else:
        import_paths = list(imports)

    import_paths.append(workspace_name)

    if label and label.repo_name:
        import_paths.append(label.repo_name)
    return import_paths

def make_imports_depset(deps, imports, workspace_name, label = None, extra_imports_depsets = []):
    """Build an imports depset from PyInfo providers and explicit import paths.

    Args:
        deps: List of targets that provide PyInfo. Their transitive imports are merged.
        imports: Explicit import path strings; see `own_import_paths`.
        workspace_name: The workspace name to include for repo-relative imports.
        label: Optional label used to resolve relative import paths.
        extra_imports_depsets: Additional depsets of imports to merge.

    Returns:
        A depset of import path strings.
    """

    # `deps` may carry rules_py's PyInfo or native @rules_python's; both expose
    # `imports`. See py_info_interop.bzl.
    transitive = [
        get_py_info(target).imports
        for target in deps
        if has_py_info(target)
    ]

    return depset(
        direct = own_import_paths(imports, workspace_name, label),
        transitive = transitive + extra_imports_depsets,
    )

def _exec_dir(root, import_path, workspace_name):
    repo, _, rest = import_path.partition("/")
    rel = rest if repo == workspace_name else "external/" + import_path
    return "/".join([p for p in (root, rel) if p]) or "."

def own_import_dirs(import_paths, files, workspace_name):
    """Map a target's own import roots to the execroot directories holding its files.

    Runfiles merge the source tree and every output root into one tree; the
    execroot keeps them apart. An import root is mapped onto each root the
    target has files on, and kept only where one of those files lies beneath
    it, so every directory returned exists. Directories inside a tree
    artifact are trusted to exist.

    Args:
        import_paths: runfiles-root-relative import roots, from `own_import_paths`.
        files: list[File], the target's own files.
        workspace_name: the main repository's name.

    Returns:
        A list of execroot-relative directories.
    """
    roots = {}
    present = {}
    trees = []
    for f in files:
        roots[f.root.path] = True
        if f.is_directory:
            trees.append(f.path + "/")
            segments = f.path.split("/")
        else:
            segments = f.dirname.split("/") if f.dirname else []
        for i in range(len(segments)):
            present["/".join(segments[:i + 1])] = True
    if files:
        present["."] = True

    dirs = []
    for import_path in import_paths:
        for root in roots:
            d = _exec_dir(root, import_path, workspace_name)
            if d in present or any([d.startswith(t) for t in trees]):
                dirs.append(d)
    return dirs

def make_import_dirs_depset(deps, import_dirs, extra_depsets = []):
    """The `import_dirs` counterpart of `make_imports_depset`.

    Args:
        deps: List of targets whose `import_dirs` are merged.
        import_dirs: The target's own directories, from `own_import_dirs`.
        extra_depsets: Additional depsets of directories to merge.

    Returns:
        A depset of execroot-relative directories, ordered like the imports.
    """
    return depset(
        direct = import_dirs,
        transitive = [get_import_dirs(target) for target in deps] + extra_depsets,
    )
