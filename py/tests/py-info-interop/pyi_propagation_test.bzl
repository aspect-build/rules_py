"""Analysis coverage for rules_python type-stub interoperability."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_python//python:defs.bzl", RulesPythonPyInfo = "PyInfo")
load("//py:defs.bzl", "PyInfo")

def _rules_python_pyi_fixture_impl(ctx):
    return [RulesPythonPyInfo(
        transitive_sources = depset(),
        transitive_pyi_files = depset(ctx.files.srcs),
    )]

rules_python_pyi_fixture = rule(
    implementation = _rules_python_pyi_fixture_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = [".pyi"]),
    },
)

def _pyi_propagation_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.equals(env, ["library.pyi"], [file.basename for file in target[PyInfo].transitive_pyi_files.to_list()])
    asserts.equals(env, [], target[PyInfo].transitive_sources.to_list())
    return analysistest.end(env)

pyi_propagation_test = analysistest.make(_pyi_propagation_test_impl)
