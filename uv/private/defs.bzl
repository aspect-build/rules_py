"Internal helpers."

load("@rules_python//python:defs.bzl", "PyInfo")
load("@with_cfg.bzl", "with_cfg")
load("//py/private:py_library.bzl", _py_library = "py_library_utils")

LIB_MODE = "//uv/private/constraints:lib_mode"

def _py_whl_library_impl(ctx):
    """A stripped-down py_library that does not add repo roots as import paths.

    Wheel libraries have explicit import paths (into site-packages) and should
    never contribute their repository root as an import root. Doing so causes
    the venv builder to walk the entire repo directory, symlinking non-Python
    files (like BUILD.bazel) into site-packages and triggering collisions.
    """
    transitive_srcs = _py_library.make_srcs_depset(ctx)
    imports = _py_library.make_imports_depset(ctx, include_repo_import = False)
    runfiles = _py_library.make_merged_runfiles(ctx, extra_runfiles = ctx.files.srcs)

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

_py_whl_library_rule = rule(
    implementation = _py_whl_library_impl,
    attrs = _py_library.attrs,
    provides = [PyInfo],
)

py_whl_library, _ = with_cfg(_py_whl_library_rule).set(Label(LIB_MODE), "whl").build()

def _lib_mode_transition_impl(settings, attr):
    return {LIB_MODE: "lib"}

lib_mode_transition = transition(
    implementation = _lib_mode_transition_impl,
    inputs = [],
    outputs = [LIB_MODE],
)

def _whl_mode_transition_impl(settings, attr):
    return {LIB_MODE: "whl"}

whl_mode_transition = transition(
    implementation = _whl_mode_transition_impl,
    inputs = [],
    outputs = [LIB_MODE],
)

def _whl_requirements_impl(ctx):
    return [DefaultInfo(files = depset(transitive = [s.files for s in ctx.attr.srcs]))]

whl_requirements = rule(
    implementation = _whl_requirements_impl,
    attrs = {
        "srcs": attr.label_list(cfg = whl_mode_transition),
    },
)
