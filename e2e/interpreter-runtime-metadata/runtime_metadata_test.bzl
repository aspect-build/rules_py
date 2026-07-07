"""Checks metadata on a provisioned PBS Python runtime."""

load("@rules_python//python:py_runtime_info.bzl", "PyRuntimeInfo")

def _assert_equal(description, expected, actual):
    if actual != expected:
        fail("{}: expected {}, got {}".format(description, expected, actual))

def _runtime_metadata_test_impl(ctx):
    runtime = ctx.attr.runtime[PyRuntimeInfo]
    version = runtime.interpreter_version_info

    _assert_equal("implementation", "cpython", runtime.implementation_name)
    _assert_equal("major", 3, version.major)
    _assert_equal("minor", 15, version.minor)
    _assert_equal("micro", 0, version.micro)
    _assert_equal("release level", "alpha", version.releaselevel)
    _assert_equal("release serial", 6, version.serial)
    _assert_equal("ABI flags", ctx.attr.abi_flags, runtime.abi_flags)

    # Free-threaded CPython keeps the same cache tag without its `t` ABI flag:
    # https://github.com/python/cpython/blob/v3.15.0a5/Python/sysmodule.c#L3570-L3576
    _assert_equal("pyc tag", "cpython-315", runtime.pyc_tag)

    executable = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.write(executable, "#!/usr/bin/env sh\n", is_executable = True)
    return [DefaultInfo(executable = executable)]

runtime_metadata_test = rule(
    implementation = _runtime_metadata_test_impl,
    attrs = {
        "abi_flags": attr.string(mandatory = True),
        "runtime": attr.label(mandatory = True, providers = [PyRuntimeInfo]),
    },
    test = True,
)
