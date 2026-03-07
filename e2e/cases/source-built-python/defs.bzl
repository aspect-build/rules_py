"""Helpers for the source-built Python e2e test."""

# -- Wrapper script to set PYTHONHOME for the source-built interpreter --

def _python_interpreter_wrapper_impl(ctx):
    """Creates a wrapper that sets PYTHONHOME before exec-ing the real interpreter.

    The cpython label should point to a configure_make target whose DefaultInfo
    contains individual output files (bin/python3.11d, lib/python3.11/, etc.)
    all sharing a common prefix directory.
    """
    all_files = ctx.attr.cpython[DefaultInfo].files.to_list()

    binary = None
    for f in all_files:
        if f.path.endswith("/bin/" + ctx.attr.binary):
            binary = f
            break

    if not binary:
        fail("Could not find bin/{} in cpython outputs: {}".format(
            ctx.attr.binary,
            [f.path for f in all_files],
        ))

    # Compute relative path from wrapper to binary. Both live under the same
    # package directory in the output tree.
    pkg = ctx.label.package
    rel_binary = binary.short_path.removeprefix(pkg + "/") if pkg else binary.short_path

    wrapper = ctx.actions.declare_file(ctx.attr.name)
    ctx.actions.write(
        output = wrapper,
        content = """\
#!/bin/bash
SCRIPT_DIR="${{0%/*}}"
BINARY_PATH="$SCRIPT_DIR/{rel_binary}"
export PYTHONHOME="${{BINARY_PATH%/bin/{binary_name}}}"
exec "$BINARY_PATH" "$@"
""".format(
            rel_binary = rel_binary,
            binary_name = ctx.attr.binary,
        ),
        is_executable = True,
    )

    # DefaultInfo.files has just the wrapper so py_runtime(interpreter=...)
    # sees a single file. All cpython outputs go into runfiles so they're
    # available at runtime for the interpreter to find its stdlib.
    return [DefaultInfo(
        files = depset([wrapper]),
        runfiles = ctx.runfiles(files = [wrapper] + all_files),
    )]

python_interpreter_wrapper = rule(
    implementation = _python_interpreter_wrapper_impl,
    attrs = {
        "cpython": attr.label(mandatory = True),
        "binary": attr.string(default = "python3.11d"),
    },
)

# -- Transition to activate the source-built Python toolchain --

def _source_built_transition_impl(settings, attr):
    return {
        "//cases/source-built-python:python_build_type": "source",
        # BCR zlib is compiled as a static archive; CPython links it into
        # shared extension modules (_zlib.so).  Without -fPIC the linker
        # fails with R_X86_64_PC32 relocation errors.
        "//command_line_option:copt": settings["//command_line_option:copt"] + ["-fPIC"],
    }

_source_built_transition = transition(
    implementation = _source_built_transition_impl,
    inputs = ["//command_line_option:copt"],
    outputs = [
        "//cases/source-built-python:python_build_type",
        "//command_line_option:copt",
    ],
)

def _source_built_test_impl(ctx):
    inner = ctx.attr.test[0]
    inner_di = inner[DefaultInfo]

    inner_executable = inner_di.files_to_run.executable

    executable = ctx.actions.declare_file(ctx.attr.name + ".sh")
    ctx.actions.write(
        output = executable,
        content = """\
#!/bin/bash
# Resolve RUNFILES_DIR from the Bazel test environment
if [[ -z "$RUNFILES_DIR" ]]; then
    if [[ -d "$TEST_SRCDIR" ]]; then
        RUNFILES_DIR="$TEST_SRCDIR"
    elif [[ -d "$0.runfiles" ]]; then
        RUNFILES_DIR="$0.runfiles"
    fi
fi
exec "$RUNFILES_DIR/{workspace}/{inner}" "$@"
""".format(
            workspace = ctx.workspace_name,
            inner = inner_executable.short_path,
        ),
        is_executable = True,
    )

    runfiles = ctx.runfiles(files = [inner_executable])
    runfiles = runfiles.merge(inner_di.default_runfiles)

    return [DefaultInfo(
        executable = executable,
        runfiles = runfiles,
    )]

source_built_test = rule(
    implementation = _source_built_test_impl,
    test = True,
    attrs = {
        "test": attr.label(
            mandatory = True,
            cfg = _source_built_transition,
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)
