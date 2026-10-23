"""Analysis test: under coverage, py_test runs Bazel's C/C++ coverage collector.

Instrumented native code a test loads (extension modules, ctypes libraries)
writes LLVM profiles or gcov data. Bazel turns those into coverage only when the
test rule has a `_collect_cc_coverage` attribute, which stages
collect_cc_coverage.sh into the test action, as for cc_test.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _cc_coverage_collector_test_impl(ctx):
    env = analysistest.begin(ctx)
    test_actions = [a for a in analysistest.target_actions(env) if a.mnemonic == "TestRunner"]
    asserts.true(env, len(test_actions) > 0, "expected a TestRunner action")
    for action in test_actions:
        asserts.true(
            env,
            any([f.basename == "collect_cc_coverage.sh" for f in action.inputs.to_list()]),
            "collect_cc_coverage.sh should be an input of the coverage test action",
        )
    return analysistest.end(env)

cc_coverage_collector_test = analysistest.make(
    _cc_coverage_collector_test_impl,
    config_settings = {
        "//command_line_option:collect_code_coverage": True,
    },
)
