# Regression test: py_library must NOT include transitive sources in DefaultInfo.files.
#
# Including transitive sources causes O(n^2) depset flattening and OOM in large
# dependency graphs. Transitive sources belong in PyInfo.transitive_sources only.
# See https://github.com/aspect-build/rules_py/pull/221.

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@aspect_rules_py//py/private:py_library.bzl", _py_library = "py_library")

def _default_info_no_transitive_srcs_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)

    default_files = target[DefaultInfo].files.to_list()
    default_basenames = sorted([f.basename for f in default_files])

    # DefaultInfo.files must contain ONLY direct srcs, not transitive.
    asserts.equals(env, ["mid.py"], default_basenames)

    return analysistest.end(env)

_default_info_no_transitive_srcs_test = analysistest.make(
    _default_info_no_transitive_srcs_impl,
)

def py_library_defaultinfo_test_suite():
    _py_library(
        name = "__leaf_lib",
        srcs = ["leaf.py"],
        tags = ["manual"],
    )

    _py_library(
        name = "__mid_lib",
        srcs = ["mid.py"],
        deps = [":__leaf_lib"],
        tags = ["manual"],
    )

    _default_info_no_transitive_srcs_test(
        name = "default_info_no_transitive_srcs_test",
        target_under_test = ":__mid_lib",
    )
