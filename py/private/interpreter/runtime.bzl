"""Python runtime toolchain rule for provisioned interpreter repositories.

A minimal replacement for the rules_python `py_runtime` + `py_runtime_pair` +
`py_exec_tools_toolchain` rule stack: one target provides the runtime and the
ToolchainInfo payloads for both the standard Python toolchain type and
rules_py's exec-tools toolchain type.

The runtime is an instance of rules_python's public PyRuntimeInfo (re-exported
here and from //py:defs.bzl): `@bazel_tools//tools/python:toolchain_type` is
the shared target-runtime contract, and rules_python's py_binary forwards the
resolved runtime provider onto built binaries, where downstream consumers
(py_zipapp_binary, py_interpreter) index it by that provider symbol.
"""

load("@rules_python//python:py_runtime_info.bzl", _PyRuntimeInfo = "PyRuntimeInfo")

PyRuntimeInfo = _PyRuntimeInfo

def _py_runtime_toolchain_impl(ctx):
    version_info = ctx.attr.interpreter_version_info
    for key in ("major", "minor", "micro"):
        if key not in version_info:
            fail("interpreter_version_info must contain '{}'".format(key))

    runtime = PyRuntimeInfo(
        interpreter = ctx.file.interpreter,
        files = depset(ctx.files.files),
        interpreter_version_info = version_info,
        implementation_name = "cpython",
        abi_flags = ctx.attr.abi_flags,
        # Freethreaded CPython keeps the same cache tag without its `t` ABI flag:
        # https://github.com/python/cpython/blob/v3.15.0a5/Python/sysmodule.c#L3570-L3576
        pyc_tag = "cpython-{}{}".format(int(version_info["major"]), int(version_info["minor"])),
        supports_build_time_venv = True,
        python_version = "PY3",
        # rules_python's own public-for-implicit-deps template files — label
        # references, not .bzl loads.
        bootstrap_template = ctx.file._bootstrap_template,
        stage2_bootstrap_template = ctx.file._stage2_bootstrap_template,
        site_init_template = ctx.file._site_init_template,
        zip_main_template = ctx.file._zip_main_template,
    )

    return [
        runtime,
        platform_common.ToolchainInfo(
            # The standard Python toolchain contract
            # (@bazel_tools//tools/python:toolchain_type).
            py2_runtime = None,
            py3_runtime = runtime,
            # The //py/private/toolchain:exec_tools_toolchain_type contract.
            exec_runtime = runtime,
        ),
        DefaultInfo(files = depset([ctx.file.interpreter], transitive = [runtime.files])),
    ]

py_runtime_toolchain = rule(
    doc = """Declares a provisioned Python runtime and its toolchain payloads.

One target serves both toolchain registrations: selected by target platform
for the standard Python toolchain type, and by exec platform for the
exec-tools toolchain type (build actions get an interpreter runnable on the
build host regardless of the target platform being built for).""",
    implementation = _py_runtime_toolchain_impl,
    attrs = {
        "interpreter": attr.label(
            doc = "The interpreter executable within `files`.",
            allow_single_file = True,
            mandatory = True,
        ),
        "files": attr.label_list(
            doc = "The complete runtime tree.",
            allow_files = True,
        ),
        "interpreter_version_info": attr.string_dict(
            doc = "Static version info: major/minor/micro required, releaselevel/serial optional.",
            mandatory = True,
        ),
        "abi_flags": attr.string(
            doc = "CPython ABI flag suffix, e.g. \"t\" for freethreaded.",
        ),
        "_bootstrap_template": attr.label(
            allow_single_file = True,
            default = "@rules_python//python/private:bootstrap_template",
        ),
        "_stage2_bootstrap_template": attr.label(
            allow_single_file = True,
            default = "@rules_python//python/private:stage2_bootstrap_template",
        ),
        "_site_init_template": attr.label(
            allow_single_file = True,
            default = "@rules_python//python/private:site_init_template",
        ),
        "_zip_main_template": attr.label(
            allow_single_file = True,
            default = "@rules_python//python/private/zipapp:zip_main_template",
        ),
    },
    provides = [PyRuntimeInfo],
)
