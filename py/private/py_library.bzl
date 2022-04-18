"Implementation for the py_library rule"

load("@bazel_skylib//lib:paths.bzl", "paths")
load("//py/private:providers.bzl", "PyWheelInfo")

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

def _make_import_path(workspace, base, imp):
    if imp.startswith(".."):
        return paths.normalize(paths.join(workspace, *base.split("/")[0:-len(imp.split("/"))]))
    else:
        return paths.normalize(paths.join(workspace, base, imp))

def _make_imports_depset(ctx):
    base = paths.dirname(ctx.build_file_path)
    import_paths = [
        _make_import_path(ctx.workspace_name, base, im)
        for im in ctx.attr.imports
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
    ]

_attrs = dict({
    "srcs": attr.label_list(
        allow_files = True,
    ),
    "deps": attr.label_list(
        allow_files = True,
        # Ideally we'd have a PyWheelInfo provider here so we can restrict the dependency set
        providers = [[PyInfo], [PyWheelInfo]],
    ),
    "data": attr.label_list(
        allow_files = True,
    ),
    "imports": attr.string_list(),
})

_providers = [
    DefaultInfo,
    PyInfo,
]

py_library_utils = struct(
    make_srcs_depset = _make_srcs_depset,
    make_imports_depset = _make_imports_depset,
    make_merged_runfiles = _make_merged_runfiles,
    implementation = _py_library_impl,
    attrs = _attrs,
    py_library_providers = _providers,
)

py_library = rule(
    implementation = py_library_utils.implementation,
    attrs = py_library_utils.attrs,
    provides = py_library_utils.py_library_providers,
)
