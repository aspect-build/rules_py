load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":defs.bzl", "console_script_name")

def _uses_explicit_script_name_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "custom-script", console_script_name("binary_name", "custom-script"))
    return unittest.end(env)

uses_explicit_script_name_test = unittest.make(_uses_explicit_script_name_test_impl)

def _defaults_to_target_name_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "binary_name", console_script_name("binary_name", None))
    return unittest.end(env)

defaults_to_target_name_test = unittest.make(_defaults_to_target_name_test_impl)

def py_entrypoint_binary_test_suite():
    unittest.suite(
        "py_entrypoint_binary_tests",
        uses_explicit_script_name_test,
        defaults_to_target_name_test,
    )
