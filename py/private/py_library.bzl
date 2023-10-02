"Implementation for the py_library rule"

load("@bazel_skylib//lib:paths.bzl", "paths")
load("//py/private:providers.bzl", "PyWheelInfo")
load("//py/private:py_wheel.bzl", py_wheel = "py_wheel_lib")

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

def _make_imports_depset(ctx):
    base = paths.dirname(ctx.build_file_path)
    import_paths = [
        _make_import_path(ctx.label, ctx.workspace_name, base, im)
        for im in ctx.attr.imports
    ] + [
        # Add the workspace name in the imports such that repo-relative imports work.
        ctx.workspace_name,
    ]

    return depset(
        direct = import_paths,
        transitive = [
            target[PyInfo].imports
            for target in ctx.attr.deps
            if PyInfo in target
        ],
    )

def _make_merged_runfiles(ctx, extra_depsets = [], extra_runfiles = [], extra_runfiles_depsets = []):
    runfiles_targets = ctx.attr.deps + ctx.attr.data
    runfiles = ctx.runfiles(
        files = ctx.files.data + extra_runfiles,
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
    runfiles = _make_merged_runfiles(ctx)
    instrumented_files_info = _make_instrumented_files_info(ctx)
    py_wheel_info = py_wheel.make_py_wheel_info(ctx, ctx.attr.deps)

    return [
        DefaultInfo(
            files = depset(direct = ctx.files.srcs, transitive = [transitive_srcs]),
            default_runfiles = runfiles,
        ),
        PyInfo(
            imports = imports,
            transitive_sources = transitive_srcs,
            has_py2_only_sources = False,
            has_py3_only_sources = True,
            uses_shared_libraries = False,
        ),
        py_wheel_info,
        instrumented_files_info,
    ]

_attrs = dict({
    "srcs": attr.label_list(
        doc = "Python source files.",
        allow_files = True,
    ),
    "deps": attr.label_list(
        doc = "Targets that produce Python code, commonly `py_library` rules.",
        allow_files = True,
        providers = [[PyInfo], [PyWheelInfo]],
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
)

py_library = rule(
    implementation = py_library_utils.implementation,
    attrs = py_library_utils.attrs,
    provides = py_library_utils.py_library_providers,
)
