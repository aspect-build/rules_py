"""Analysis tests for py_runtime_toolchain's PyRuntimeInfo."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_python//python:features.bzl", rules_python_features = "features")
load("//py/private/interpreter:runtime.bzl", "PyRuntimeInfo", "py_runtime_toolchain")

def _venv_bin_files_test_impl(ctx):
    env = analysistest.begin(ctx)
    runtime = analysistest.target_under_test(env)[PyRuntimeInfo]

    # rules_python 2.0 added the field. Its Windows venv code reads it, so a
    # runtime without it fails analysis of any rules_python binary there.
    if rules_python_features.version.startswith("1."):
        asserts.false(env, hasattr(runtime, "venv_bin_files"))
    else:
        asserts.equals(env, ["python313.dll"], [f.basename for f in runtime.venv_bin_files])
    return analysistest.end(env)

_venv_bin_files_test = analysistest.make(_venv_bin_files_test_impl)

def runtime_test_suite():
    write_file(
        name = "_fake_python_exe",
        out = "fake_runtime/python.exe",
        content = [""],
        tags = ["manual"],
    )
    write_file(
        name = "_fake_python_dll",
        out = "fake_runtime/python313.dll",
        content = [""],
        tags = ["manual"],
    )
    py_runtime_toolchain(
        name = "_fake_windows_runtime",
        interpreter = ":_fake_python_exe",
        files = [":_fake_python_exe", ":_fake_python_dll"],
        interpreter_version_info = {"major": "3", "minor": "13", "micro": "0"},
        venv_dlls = [":_fake_python_dll"],
        tags = ["manual"],
    )
    _venv_bin_files_test(
        name = "venv_bin_files_test",
        target_under_test = ":_fake_windows_runtime",
    )
