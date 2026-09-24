"""Analysis test: a rules_py stub survives merging into rules_python's PyInfo."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_python//python:py_info.bzl", "PyInfo")

def _basenames(files):
    return sorted([file.basename for file in files.to_list()])

def _merged_stubs_test_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[PyInfo]
    asserts.equals(env, [], _basenames(info.direct_pyi_files), "the wrapper declares no stubs of its own")
    asserts.equals(env, ["lib.pyi"], _basenames(info.transitive_pyi_files))
    asserts.equals(env, ["lib.py"], _basenames(info.transitive_sources), "the stub is not a runtime source")
    return analysistest.end(env)

merged_stubs_test = analysistest.make(_merged_stubs_test_impl)
