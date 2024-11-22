"""A re-implementation of [py_library](https://bazel.build/reference/be/python#py_library).

Supports "virtual" dependencies with a `virtual_deps` attribute, which lists packages which are required
without binding them to a particular version of that package.
"""

load("@rules_python//python:defs.bzl", "PyInfo")
load("@bazel_skylib//lib:paths.bzl", "paths")
load("@bazel_skylib//lib:new_sets.bzl", "sets")
load("//py/private:providers.bzl", "PyVirtualInfo")

def _make_instrumented_files_info(ctx, extra_source_attributes = [], extra_dependency_attributes = []):
    return coverage_common.instrumented_files_info(
        ctx,
        source_attributes = ["srcs"] + extra_source_attributes,
        dependency_attributes = ["data", "deps"] + extra_dependency_attributes,
        extensions = ["py"],
    )

def _make_srcs_depset(ctx):
    return depset(
        order = "postorder",
        direct = ctx.files.srcs,
        transitive = [
            target[PyInfo].transitive_sources
            for target in ctx.attr.deps
            if PyInfo in target
        ],
    )

def _make_virtual_depset(ctx):
    return depset(
        order = "postorder",
        direct = getattr(ctx.attr, "virtual_deps", []),
        transitive = [
            target[PyVirtualInfo].dependencies
            for target in ctx.attr.deps
            if PyVirtualInfo in target
        ],
    )

def _make_resolved_virtual_depset(target):
    transitive = [target[DefaultInfo].files]
    if PyInfo in target:
        transitive.append(target[PyInfo].transitive_sources)

    return depset(
        order = "postorder",
        transitive = transitive,
    )

def _make_virtual_resolutions_depset(ctx):
    return depset(
        order = "postorder",
        direct = [
            struct(virtual = v, target = k)
            for k, v in ctx.attr.resolutions.items()
        ],
        transitive = [
            target[PyVirtualInfo].resolutions
            for target in ctx.attr.deps
            if PyVirtualInfo in target
        ],
    )

def _resolve_virtuals(ctx, ignore_missing = False):
    virtual = _make_virtual_depset(ctx).to_list()
    resolutions = _make_virtual_resolutions_depset(ctx).to_list()

    # Check for duplicate virtual dependency names. Those that map to the same resolution target would have been merged by the depset for us.
    seen = {}
    v_srcs = []
    v_runfiles = []
    v_imports = []

    for i, resolution in enumerate(resolutions):
        if resolution.virtual in seen:
            conflicts_with = resolutions[seen[resolution.virtual]].target
            fail("Conflict in virtual dependency resolutions while resolving '{}'. Dependency is resolved by {} and {}".format(resolution.virtual, str(resolution.target), str(conflicts_with)))

        seen.update([[resolution.virtual, i]])

        v_srcs.append(_make_resolved_virtual_depset(resolution.target))
        v_runfiles.append(resolution.target[DefaultInfo].default_runfiles.files)

        if PyInfo in resolution.target:
            v_imports.append(resolution.target[PyInfo].imports)

    missing = sets.to_list(sets.difference(sets.make(virtual), sets.make(seen.keys())))
    if len(missing) > 0 and not ignore_missing:
        fail("The following dependencies were marked as virtual, but no concrete label providing them was given: {}".format(", ".join(missing)))

    return struct(
        srcs = v_srcs,
        runfiles = v_runfiles,
        imports = v_imports,
        missing = missing,
    )

def _make_import_path(label, workspace, base, imp):
    if imp.startswith("/"):
        fail(
            "Import path '{imp}' on target {target} is invalid. Absolute paths are not supported.".format(
                imp = imp,
                target = str(label),
            ),
        )

    base_segments = base.split("/")
    path_segments = imp.split("/")

    relative_segments = 0
    for segment in path_segments:
        if segment == "..":
            relative_segments += 1
        else:
            break

    # Check if the relative segments that the import path starts with match the number of segments in the base path
    # that would break use out of the workspace root.
    # The +1 is base_segments would take the path to the root, then one more to escape.
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
        return paths.normalize(paths.join(workspace, base, imp))

def _make_imports_depset(ctx, imports = [], extra_imports_depsets = []):
    base = paths.dirname(ctx.build_file_path)
    import_paths = [
        _make_import_path(ctx.label, ctx.label.workspace_name or ctx.workspace_name, base, im)
        for im in getattr(ctx.attr, "imports", imports)
    ] + [
        # Add the workspace name in the imports such that repo-relative imports work.
        ctx.workspace_name,
    ]

    # Handle the case where its a target from an external workspace that uses repo-relative imports
    if ctx.label.workspace_name:
        import_paths.append(ctx.label.workspace_name)

    return depset(
        direct = import_paths,
        transitive = [
            target[PyInfo].imports
            for target in getattr(ctx.attr, "deps", [])
            if PyInfo in target
        ] + extra_imports_depsets,
    )

def _make_merged_runfiles(ctx, extra_depsets = [], extra_runfiles = [], extra_runfiles_depsets = []):
    runfiles_targets = getattr(ctx.attr, "deps", []) + getattr(ctx.attr, "data", [])
    runfiles = ctx.runfiles(
        files = getattr(ctx.files, "data", []) + extra_runfiles,
        transitive_files = depset(
            transitive = extra_depsets,
        ),
    )

    runfiles = runfiles.merge_all([
        target[DefaultInfo].default_runfiles
        for target in runfiles_targets
    ] + extra_runfiles_depsets)

    return runfiles

def _py_library_impl(ctx):
    transitive_srcs = _make_srcs_depset(ctx)
    imports = _make_imports_depset(ctx)
    virtuals = _make_virtual_depset(ctx)
    resolutions = _make_virtual_resolutions_depset(ctx)
    runfiles = _make_merged_runfiles(ctx, extra_runfiles = ctx.files.srcs)
    instrumented_files_info = _make_instrumented_files_info(ctx)

    return [
        DefaultInfo(
            files = depset(direct = ctx.files.srcs),
            default_runfiles = runfiles,
        ),
        PyInfo(
            imports = imports,
            transitive_sources = transitive_srcs,
            has_py2_only_sources = False,
            has_py3_only_sources = True,
            uses_shared_libraries = False,
        ),
        PyVirtualInfo(
            dependencies = virtuals,
            resolutions = resolutions,
        ),
        instrumented_files_info,
    ]

_attrs = dict({
    "srcs": attr.label_list(
        doc = "Python source files.",
        allow_files = True,
    ),
    "deps": attr.label_list(
        doc = "Targets that produce Python code, commonly `py_library` rules.",
        providers = [[PyInfo], [PyVirtualInfo]],
    ),
    "data": attr.label_list(
        doc = """Runtime dependencies of the program.

        The transitive closure of the `data` dependencies will be available in the `.runfiles`
        folder for this binary/test. The program may optionally use the Runfiles lookup library to
        locate the data files, see https://pypi.org/project/bazel-runfiles/.
        """,
        allow_files = True,
    ),
    "imports": attr.string_list(
        doc = "List of import directories to be added to the PYTHONPATH.",
        default = [],
    ),
    "resolutions": attr.label_keyed_string_dict(
        doc = """Satisfy a virtual_dep with a mapping from external package name to the label of an installed package that provides it.
        See [virtual dependencies](/docs/virtual_deps.md).
        """,
    ),
})

_providers = [
    DefaultInfo,
    PyInfo,
]

py_library_utils = struct(
    # keep-sorted
    attrs = _attrs,
    implementation = _py_library_impl,
    make_imports_depset = _make_imports_depset,
    make_instrumented_files_info = _make_instrumented_files_info,
    make_merged_runfiles = _make_merged_runfiles,
    make_srcs_depset = _make_srcs_depset,
    py_library_providers = _providers,
    resolve_virtuals = _resolve_virtuals,
)

py_library = rule(
    implementation = py_library_utils.implementation,
    attrs = dict({
        "virtual_deps": attr.string_list(allow_empty = True, default = []),
    }, **py_library_utils.attrs),
    provides = py_library_utils.py_library_providers,
)
