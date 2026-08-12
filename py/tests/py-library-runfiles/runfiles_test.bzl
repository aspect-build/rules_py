"""Analysis coverage for py_library's source-free default runfiles."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _has(paths, suffix):
    return any([path.endswith(suffix) for path in paths])

def _py_library_runfiles_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    paths = [f.short_path for f in target[DefaultInfo].default_runfiles.files.to_list()]
    asserts.false(env, _has(paths, "/library.py"), "library sources stay in PyInfo")
    asserts.true(env, _has(paths, "/runtime_data.py"), "library data remains in runfiles")
    return analysistest.end(env)

py_library_runfiles_test = analysistest.make(_py_library_runfiles_test_impl)

def _py_venv_runfiles_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    paths = [f.short_path for f in target[DefaultInfo].default_runfiles.files.to_list()]
    for source in ctx.attr.expected_sources:
        asserts.true(env, _has(paths, "/" + source), "public py_venv retains source " + source)
    return analysistest.end(env)

py_venv_runfiles_test = analysistest.make(
    _py_venv_runfiles_test_impl,
    attrs = {"expected_sources": attr.string_list(mandatory = True)},
)
