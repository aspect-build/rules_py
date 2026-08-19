"""Analysis coverage for py_library's source-free default runfiles."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//py/private:py_info.bzl", "PyInfo")
load("//py/private/py_venv:defs.bzl", "VirtualenvInfo")

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

def _private_venv_provider_test_impl(ctx):
    env = analysistest.begin(ctx)
    venv = analysistest.target_under_test(env)
    consumer = ctx.attr.consumer
    venv_info = venv[VirtualenvInfo]
    venv_paths = [f.short_path for f in venv[DefaultInfo].default_runfiles.files.to_list()]
    consumer_paths = [f.short_path for f in consumer[DefaultInfo].default_runfiles.files.to_list()]
    source_paths = [f.short_path for f in venv_info.transitive_sources.to_list()]

    asserts.true(env, venv_info.bin_python.short_path in venv_paths, "lib venv retains bin/python")
    asserts.equals(env, venv_info.imports.to_list(), consumer[PyInfo].imports.to_list())
    asserts.equals(env, source_paths, [f.short_path for f in consumer[PyInfo].transitive_sources.to_list()])
    for source in ctx.attr.expected_sources:
        asserts.true(env, _has(source_paths, "/" + source), "VirtualenvInfo retains source " + source)
        asserts.true(env, _has(consumer_paths, "/" + source), "consumer restores source " + source)
    return analysistest.end(env)

private_venv_provider_test = analysistest.make(
    _private_venv_provider_test_impl,
    attrs = {
        "consumer": attr.label(mandatory = True),
        "expected_sources": attr.string_list(mandatory = True),
    },
)

def _indexed_imports_layout_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    outputs = [
        output.short_path
        for action in analysistest.target_actions(env)
        for output in action.outputs.to_list()
    ]
    runfiles = [file.short_path for file in target[DefaultInfo].default_runfiles.files.to_list()]
    for suffix in [
        "/site-packages/.aspect_rules_py_import_index",
        "/site-packages/_aspect_rules_py_import_index.py",
    ]:
        matches = [path for path in outputs if path.endswith(suffix)]
        asserts.equals(env, 1 if ctx.attr.expect_index else 0, len(matches))
        if matches:
            asserts.true(env, matches[0] in runfiles)
    return analysistest.end(env)

indexed_imports_layout_test = analysistest.make(
    _indexed_imports_layout_test_impl,
    attrs = {"expect_index": attr.bool(mandatory = True)},
    config_settings = {
        str(Label("//py:experimental_indexed_imports")): True,
    },
)
