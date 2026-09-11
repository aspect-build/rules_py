"""Analysis test: rules_python `pyi_srcs` surface in rules_py's `PyInfo`."""

load("@aspect_rules_py//py:defs.bzl", "PyInfo")
load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _basenames(files):
    return sorted([file.basename for file in files.to_list()])

def _foreign_stubs_test_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[PyInfo]
    asserts.equals(env, ["stubbed.pyi"], _basenames(info.transitive_pyi_files))
    asserts.equals(env, ["stubbed.py"], _basenames(info.transitive_sources), "the stub is not a runtime source")
    return analysistest.end(env)

foreign_stubs_test = analysistest.make(_foreign_stubs_test_impl)
