def _uv_lock_test_impl(ctx):
    """Implementation of the uv_lock test rule.

    Validates that the lockfile is synchronized with pyproject.toml and
    structurally valid using uv's native --check flag. Fails fast without
    mutating the workspace.
    """
    uv_files = ctx.attr.uv[DefaultInfo].files.to_list()
    if not uv_files:
        fail("uv target %s did not provide any files" % ctx.attr.uv)
    uv_path = uv_files[0]

    script = ctx.actions.declare_file(ctx.attr.name + ".sh")

    uv_runfile = uv_path.path.split("/")[1] + "/uv"

    script_content = """#!/bin/bash
set -e

WORKSPACE_ROOT=$(pwd)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ "$SCRIPT_DIR" == *.runfiles/_main ]]; then
    RUNFILES="$(dirname "$SCRIPT_DIR")"
else
    RUNFILES="$SCRIPT_DIR/$(basename "$0").runfiles"
fi
UV_ABS="$RUNFILES/{uv}"

cd "$WORKSPACE_ROOT"

if ! "$UV_ABS" lock --python {python_version} --check; then
    echo "ERROR: uv.lock is out of sync with pyproject.toml or is structurally corrupt."
    echo "Run: bazel run {update_target}"
    exit 1
fi

echo "Lock file is up to date, unmodified, and hashes are valid."
""".format(
        uv = uv_runfile,
        update_target = "//{}:{}.update".format(ctx.label.package, ctx.attr.target_name),
        python_version = ctx.attr.python_version,
    )

    ctx.actions.write(
        output = script,
        content = script_content,
        is_executable = True,
    )

    runfiles = ctx.runfiles(files = [uv_path, ctx.file.pyproject, ctx.file.lock])

    return [DefaultInfo(
        executable = script,
        runfiles = runfiles,
    )]

_uv_lock_test = rule(
    implementation = _uv_lock_test_impl,
    attrs = {
        "pyproject": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "Path to pyproject.toml file",
        ),
        "lock": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "Path to uv.lock file",
        ),
        "target_name": attr.string(
            mandatory = True,
            doc = "Base name for the update target",
        ),
        "uv": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "The UV binary target to use",
        ),
        "python_version": attr.string(
            mandatory = True,
            doc = "Python version to pass to uv lock (e.g. '3.11')",
        ),
    },
    test = True,
)

def _uv_lock_update_impl(ctx):
    """Implementation of the uv_lock update rule.

    Regenerates the lockfile using the specified Python version to ensure
    hermetic resolution regardless of local virtual environments or system
    Python installations.
    """
    script = ctx.actions.declare_file(ctx.attr.name + ".sh")

    uv_files = ctx.attr.uv[DefaultInfo].files.to_list()
    if not uv_files:
        fail("uv target %s did not provide any files" % ctx.attr.uv)
    uv_path = uv_files[0]

    uv_runfile = uv_path.path.split("/")[1] + "/uv"

    script_content = """#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ "$SCRIPT_DIR" == *.runfiles/_main ]]; then
    RUNFILES="$(dirname "$SCRIPT_DIR")"
else
    RUNFILES="$SCRIPT_DIR/$(basename "$0").runfiles"
fi
UV="$RUNFILES/{uv}"

if [ -n "$BUILD_WORKSPACE_DIRECTORY" ]; then
    WORKSPACE_ROOT="$BUILD_WORKSPACE_DIRECTORY"
else
    WORKSPACE_ROOT=$(pwd)
fi

cd "$WORKSPACE_ROOT"

if ! "$UV" lock --python {python_version} "$@" 2>&1; then
    echo "WARNING: 'uv lock' failed. The lockfile may be corrupt."
    echo "Attempting to regenerate from scratch..."
    rm -f {lock_file}
    "$UV" lock --python {python_version} "$@"
fi

echo "Lock file updated: {lock_file}"
""".format(
        uv = uv_runfile,
        lock_file = ctx.attr.lock_file,
        python_version = ctx.attr.python_version,
    )

    ctx.actions.write(
        output = script,
        content = script_content,
        is_executable = True,
    )

    runfiles = ctx.runfiles(files = [uv_path])

    return [DefaultInfo(
        executable = script,
        runfiles = runfiles,
    )]

_uv_lock_update = rule(
    implementation = _uv_lock_update_impl,
    attrs = {
        "lock_file": attr.string(mandatory = True),
        "uv": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "The UV binary target to use",
        ),
        "python_version": attr.string(
            mandatory = True,
            doc = "Python version to pass to uv lock (e.g. '3.11')",
        ),
    },
    executable = True,
)

def uv_lock(name, pyproject = "pyproject.toml", lock = "uv.lock", uv = "@uv//:uv", python_version = None, **kwargs):
    """Defines a uv.lock filegroup, update target, and test target.

    Args:
        name: Base name for generated targets.
        pyproject: Label for the pyproject.toml file.
        lock: Label for the uv.lock file.
        uv: Label for the UV binary target.
        python_version: Python version passed to uv lock to ensure hermetic
            resolution (e.g. "3.11"). Must be provided explicitly.
        **kwargs: Additional arguments forwarded to native targets.
    """
    if not python_version:
        fail("uv_lock requires an explicit python_version. " +
             "Load it from your uv hub repository (e.g. @pystar//:python_version.bzl).")

    tags = kwargs.pop("tags", [])

    native.filegroup(
        name = name,
        srcs = [lock],
        visibility = kwargs.get("visibility", ["//visibility:public"]),
    )

    _uv_lock_update(
        name = name + ".update",
        lock_file = lock,
        uv = uv,
        python_version = python_version,
        tags = tags + ["requires-network", "no-sandbox", "no-remote-exec"],
        visibility = kwargs.get("visibility", ["//visibility:public"]),
    )

    _uv_lock_test(
        name = name + ".test",
        pyproject = pyproject,
        lock = lock,
        target_name = name,
        uv = uv,
        python_version = python_version,
        tags = tags + ["requires-network", "local"],
        visibility = kwargs.get("visibility", ["//visibility:public"]),
    )

    native.alias(
        name = name + "_test",
        actual = ":" + name + ".test",
    )
