load("@aspect_rules_py//py:defs.bzl", "py_library", "py_test")

py_library(
    name = "foo",
    srcs = ["foo.py"],
    imports = ["."],
)

py_test(
    name = "test_without_pytest_main",
    srcs = ["tests/test_subdir.py"],
    deps = [":foo"],
)

py_test(
    name = "test_with_pytest_main",
    srcs = ["tests/test_subdir.py"],
    deps = [":foo"],
    pytest_main = True,
)
