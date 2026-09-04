"""Runfiles assertions for all bytecode modes on one shared py_venv."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//py/private:pyc.bzl", "FirstPartyPycInfo")

def _has(paths, suffix):
    return any([path.endswith(suffix) for path in paths])

def _mapping_has(entries, path, suffix):
    return any([entry.path == path and entry.target_file.short_path.endswith(suffix) for entry in entries.to_list()])

def _pyc_runfiles_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    paths = [f.short_path for f in target[DefaultInfo].default_runfiles.files.to_list()]
    mode = ctx.attr.mode
    module = ctx.attr.module

    has_source = _has(paths, "/{}.py".format(module))
    has_legacy = _has(paths, "/{}.pyc".format(module))
    has_pycache = any(["/__pycache__/{}.".format(module) in path and path.endswith(".pyc") for path in paths])

    asserts.equals(env, mode != "pyc_only" or ctx.attr.protect_source, has_source, "source retention")
    asserts.equals(env, mode == "pyc_only" and ctx.attr.expect_legacy, has_legacy, "colocated sourceless bytecode")
    asserts.equals(env, mode == "pyc" and ctx.attr.expect_pyc, has_pycache, "PEP 3147 cache bytecode")
    asserts.equals(env, mode != "source", FirstPartyPycInfo in target, "bytecode provider is opt-in")
    if ctx.attr.pyc_tag:
        asserts.true(
            env,
            any(["/__pycache__/{}.{}.pyc".format(module, ctx.attr.pyc_tag) in path for path in paths]),
            "PEP 3147 cache tag",
        )
    if ctx.attr.check_mappings:
        runfiles = target[DefaultInfo].default_runfiles
        asserts.true(env, _mapping_has(runfiles.symlinks, "mapped.py", "/entry_a.py"), "data symlink preserved")
        asserts.true(env, _mapping_has(runfiles.root_symlinks, "root-mapped.py", "/entry_a.py"), "data root symlink preserved")
    for suffix in ctx.attr.expect_suffixes:
        asserts.true(env, _has(paths, suffix), "expected runfile " + suffix)
    if ctx.attr.forbid_entry_substring:
        asserts.false(
            env,
            any([ctx.attr.forbid_entry_substring in entry.source.short_path for entry in target[FirstPartyPycInfo].entries.to_list()]),
            "third-party sources are not first-party bytecode entries",
        )
    return analysistest.end(env)

pyc_runfiles_test = analysistest.make(
    _pyc_runfiles_test_impl,
    attrs = {
        "mode": attr.string(mandatory = True),
        "module": attr.string(default = "entry_a"),
        "pyc_tag": attr.string(default = ""),
        "check_mappings": attr.bool(default = False),
        "expect_pyc": attr.bool(default = True),
        "expect_legacy": attr.bool(default = True),
        "protect_source": attr.bool(default = False),
        "forbid_entry_substring": attr.string(default = ""),
        "expect_suffixes": attr.string_list(default = []),
    },
)

def _pyc_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.expected_error)
    return analysistest.end(env)

pyc_failure_test = analysistest.make(
    _pyc_failure_test_impl,
    attrs = {"expected_error": attr.string(mandatory = True)},
    expect_failure = True,
)
