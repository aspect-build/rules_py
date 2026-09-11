"""Analysis test: generated `_pb2.pyi` stubs surface in rules_py's `PyInfo`."""

load("@aspect_rules_py//py:defs.bzl", "PyInfo")
load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _basenames(files):
    return sorted([file.basename for file in files.to_list()])

def _generated_stubs_test_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[PyInfo]
    asserts.true(env, "greeting_pb2.pyi" in _basenames(info.transitive_pyi_files), "py_proto_library's stub propagates")
    asserts.false(env, "greeting_pb2.pyi" in _basenames(info.transitive_sources), "the stub is not a runtime source")
    return analysistest.end(env)

generated_stubs_test = analysistest.make(_generated_stubs_test_impl)
