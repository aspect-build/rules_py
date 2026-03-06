"""Helpers for the source-built Python e2e test."""

# -- Build CPython from source as a Bazel action --

def _build_cpython_impl(ctx):
    """Builds CPython from source using ./configure && make && make install."""
    install_dir = ctx.actions.declare_directory(ctx.attr.name)

    src_files = ctx.attr.src[DefaultInfo].files

    # Find the configure script — pick the one with the shortest path
    # (the top-level one, vs. subdirectory configure scripts).
    configure = None
    for f in src_files.to_list():
        if f.basename == "configure":
            if configure == None or len(f.path) < len(configure.path):
                configure = f

    if not configure:
        fail("Could not find 'configure' script in source files")

    ctx.actions.run_shell(
        inputs = src_files,
        outputs = [install_dir],
        command = """\
set -euo pipefail
SRC_DIR="$(cd "$(dirname "{configure}")" && pwd)"
INSTALL_DIR="$(pwd)/{install_dir}"

cd "$SRC_DIR"
./configure \
    --prefix="$INSTALL_DIR" \
    --with-ensurepip=install \
    --disable-test-modules \
    --with-pydebug \
    2>&1

make -j"$(nproc)" 2>&1
make install 2>&1
""".format(
            configure = configure.path,
            install_dir = install_dir.path,
        ),
        mnemonic = "BuildCPython",
        progress_message = "Building CPython from source",
        use_default_shell_env = True,
    )

    return [DefaultInfo(files = depset([install_dir]))]

build_cpython = rule(
    implementation = _build_cpython_impl,
    attrs = {
        "src": attr.label(mandatory = True),
    },
)

# -- Wrapper script to set PYTHONHOME --

def _python_interpreter_wrapper_impl(ctx):
    """Creates a wrapper script that sets PYTHONHOME before exec-ing the real interpreter."""
    cpython_tree = None
    for f in ctx.attr.cpython[DefaultInfo].files.to_list():
        if f.is_directory:
            cpython_tree = f
            break

    if not cpython_tree:
        fail("No directory (tree artifact) found in cpython outputs")

    wrapper = ctx.actions.declare_file(ctx.attr.name)
    ctx.actions.write(
        output = wrapper,
        content = """\
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export PYTHONHOME="$SCRIPT_DIR/{tree_basename}"
exec "$PYTHONHOME/bin/{binary}" "$@"
""".format(
            tree_basename = cpython_tree.basename,
            binary = ctx.attr.binary,
        ),
        is_executable = True,
    )

    return [DefaultInfo(
        files = depset([wrapper]),
        runfiles = ctx.runfiles(files = [cpython_tree]),
    )]

python_interpreter_wrapper = rule(
    implementation = _python_interpreter_wrapper_impl,
    attrs = {
        "cpython": attr.label(mandatory = True),
        "binary": attr.string(default = "python3.11"),
    },
)

# -- Transition to activate the source-built Python toolchain --

def _source_built_transition_impl(settings, attr):
    return {"//cases/source-built-python:python_build_type": "source"}

_source_built_transition = transition(
    implementation = _source_built_transition_impl,
    inputs = [],
    outputs = ["//cases/source-built-python:python_build_type"],
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
