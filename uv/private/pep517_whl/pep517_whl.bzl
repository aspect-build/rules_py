"""PEP 517 sdist to anyarch whl build rule.

Uses `python -m build` (the pypa/build frontend) which delegates to whatever
build backend the sdist declares in its `[build-system]` table.
"""

load("@bazel_lib//lib:resource_sets.bzl", "resource_set")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN")
load(
    ":common.bzl",
    "PEP517_WHL_ATTRS",
    "TARGET_EXEC_GROUP",
    "common_env",
    "memory_args",
    "patch_args_and_inputs",
    "tool_files_to_run",
    "wheel_providers",
)

def _pep517_whl(ctx):
    archive = ctx.file.src

    # Fixed name; the backend picks the real filename at build time and the
    # helper renames onto this. Consumers read identity from dist-info only.
    wheel_file = ctx.actions.declare_file(ctx.label.name + ".whl")
    patch_args, patch_inputs = patch_args_and_inputs(ctx)

    # The build tool is a py_binary wrapping build_helper.py. Using it as
    # a tool (not just an input) causes Bazel to materialize its runfiles in
    # the action sandbox, which means the venv shim can find the interpreter
    # via the standard runfiles mechanism regardless of whether the interpreter
    # comes from an external repo or the main workspace.
    tool = tool_files_to_run(ctx)
    ctx.actions.run(
        mnemonic = "PySdistBuild",
        progress_message = "Source compiling {} to a whl".format(archive.basename),
        executable = tool,
        toolchain = None,
        arguments = ctx.attr.args + [patch_args] + memory_args(ctx) + [
            archive.path,
            wheel_file.path,
        ],
        inputs = depset([archive], transitive = [patch_inputs]),
        tools = [tool],
        outputs = [wheel_file],
        env = common_env(ctx),
        exec_group = TARGET_EXEC_GROUP,
        resource_set = resource_set(ctx.attr),
    )

    return wheel_providers(wheel_file, ctx.attr.console_scripts)

pep517_whl = rule(
    implementation = _pep517_whl,
    doc = """PEP 517 sdist to anyarch whl build rule.

Consumes a sdist artifact and performs a build of that artifact with the
specified Python dependencies under the configured Python toolchain.

""",
    attrs = PEP517_WHL_ATTRS,
    exec_groups = {
        TARGET_EXEC_GROUP: exec_group(
            toolchains = [
                PY_TOOLCHAIN,
            ],
        ),
    },
)
