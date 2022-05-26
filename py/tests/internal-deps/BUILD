load("//py:defs.bzl", "py_binary", "py_test", rules_py_py_library = "py_library")
load("@aspect_bazel_lib//lib:write_source_files.bzl", "write_source_files")

rules_py_py_library(
    name = "init",
    srcs = [
        "__init__.py",
    ],
)

rules_py_py_library(
    name = "add",
    srcs = [
        "add.py",
    ],
    deps = [
        ":init",
    ],
)

rules_py_py_library(
    name = "sub",
    srcs = [
        "sub.py",
    ],
    deps = [
        ":init",
    ],
)

py_library(
    name = "pi",
    srcs = [
        "pi.py",
    ],
    deps = [
        ":init",
    ],
)

py_binary(
    name = "main",
    srcs = [
        "__main__.py",
    ],
    deps = [
        ":add",
        ":pi",
        ":sub",
    ],
)

py_test(
    name = "assert",
    srcs = [
        "__main__.py",
    ],
    deps = [
        ":add",
        ":pi",
        ":sub",
    ],
)
