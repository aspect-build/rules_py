"""Checks bytecode identity on a provisioned PBS runtime pair."""

def _bytecode_magic_test_impl(ctx):
    runtime_pair = ctx.attr.runtime_pair[platform_common.ToolchainInfo]
    if runtime_pair.py2_runtime != None:
        fail("PBS runtime pair unexpectedly contains a Python 2 runtime")
    if runtime_pair.py3_runtime == None:
        fail("PBS runtime pair lost its Python 3 runtime")

    version = runtime_pair.py3_runtime.interpreter_version_info
    actual_version = "{}.{}".format(version.major, version.minor)
    if actual_version != ctx.attr.expected_python_version:
        fail("expected Python {}, got {}".format(
            ctx.attr.expected_python_version,
            actual_version,
        ))

    actual = getattr(runtime_pair, "pyc_magic_number", None)
    if actual != ctx.attr.expected_magic_number:
        fail("expected PYC_MAGIC_NUMBER {}, got {}".format(
            ctx.attr.expected_magic_number,
            actual,
        ))

    executable = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.write(executable, "#!/usr/bin/env sh\n", is_executable = True)
    return [DefaultInfo(executable = executable)]

bytecode_magic_test = rule(
    implementation = _bytecode_magic_test_impl,
    attrs = {
        "expected_magic_number": attr.int(mandatory = True),
        "expected_python_version": attr.string(mandatory = True),
        "runtime_pair": attr.label(
            mandatory = True,
            providers = [platform_common.ToolchainInfo],
        ),
    },
    test = True,
)
