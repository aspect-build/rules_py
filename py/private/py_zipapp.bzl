"""Implementation for py_zipapp_binary rule.

Creates a self-contained Python zipapp executable that doesn't require a virtualenv.
This is a hermetic alternative to py_venv_binary that avoids symlink issues.

The zipapp preserves the Bazel runfiles directory structure and injects
AspectPyInfo import paths into sys.path at startup.
"""

load("@bazel_lib//lib:paths.bzl", "to_rlocation_path")
load("//py/private:py_library.bzl", _py_library = "py_library_utils")
load("//py/private:py_semantics.bzl", _py_semantics = "semantics")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN")

# Template for the __main__.py that bootstraps the zipapp.
# Injects AspectPyInfo import paths into sys.path so that package imports
# resolve correctly inside the zipapp.
_ZIPAPP_MAIN_PY = '''#!/usr/bin/env python3
"""Auto-generated __main__.py for zipapp execution."""

import sys
import os

# The zipapp itself is on sys.path[0]
_zipapp = sys.path[0]

# Inject import paths derived from AspectPyInfo at build time.
_IMPORTS = {imports!r}
for _imp in _IMPORTS:
    _path = os.path.join(_zipapp, _imp)
    if _path not in sys.path:
        sys.path.append(_path)

# Execute the entry point
if __name__ == "__main__":
    import runpy
    runpy.run_module("{entry_module}", run_name="__main__", alter_sys=True)
'''

def _py_zipapp_binary_impl(ctx):
    """Build a Python zipapp executable.

    Creates a .pyz file that contains all dependencies and can be executed
    directly with a Python interpreter. The zipapp preserves runfiles paths
    and injects AspectPyInfo imports at startup for correct module resolution.
    """
    py_toolchain = _py_semantics.resolve_toolchain(ctx)

    # Collect all transitive sources and imports
    srcs_depset = _py_library.make_srcs_depset(ctx)
    virtual_resolution = _py_library.resolve_virtuals(ctx)
    imports_depset = _py_library.make_imports_depset(ctx, extra_imports_depsets = virtual_resolution.imports)

    main_file = ctx.file.main
    if main_file == None:
        fail("main file must be specified")

    # Determine entry module from main file rlocation path
    entry_rloc = to_rlocation_path(ctx, main_file)
    if entry_rloc.endswith(".py"):
        entry_module = entry_rloc[:-3].replace("/", ".").replace("\\", ".")
    else:
        entry_module = entry_rloc.replace("/", ".").replace("\\", ".")
    entry_module = entry_module.lstrip(".")

    if ctx.attr.entry_point:
        entry_module = ctx.attr.entry_point

    # Build a manifest mapping source file paths -> destination paths inside zipapp.
    # Destinations use rlocation paths so that imports resolve relative to the zipapp root.
    manifest_entries = []
    seen_dst = {}

    def _add_file(file):
        dst = to_rlocation_path(ctx, file)
        if dst not in seen_dst:
            seen_dst[dst] = True
            manifest_entries.append("{}={}".format(file.path, dst))

    for f in ctx.files.srcs:
        _add_file(f)
    for f in ctx.files.deps:
        _add_file(f)
    for f in srcs_depset.to_list():
        _add_file(f)
    for dep in virtual_resolution.srcs:
        for f in dep.to_list():
            _add_file(f)

    # Add the main entry point and __main__.py
    _add_file(main_file)

    main_py = ctx.actions.declare_file("{}_zipapp_main.py".format(ctx.attr.name))
    ctx.actions.write(
        output = main_py,
        content = _ZIPAPP_MAIN_PY.format(
            imports = imports_depset.to_list(),
            entry_module = entry_module,
        ),
    )
    manifest_entries.append("{}={}".format(main_py.path, "__main__.py"))

    manifest_file = ctx.actions.declare_file("{}.zipapp.manifest".format(ctx.attr.name))
    ctx.actions.write(manifest_file, "\n".join(manifest_entries))

    zipapp_file = ctx.actions.declare_file("{}.pyz".format(ctx.attr.name))

    # Use the hermetic Python interpreter from the toolchain, not host python3.
    python_bin = py_toolchain.python.path
    if py_toolchain.runfiles_interpreter:
        python_bin = to_rlocation_path(ctx, py_toolchain.python)

    ctx.actions.run_shell(
        outputs = [zipapp_file],
        inputs = ctx.files.srcs + ctx.files.deps + srcs_depset.to_list() + [main_file, main_py, manifest_file],
        command = """set -euo pipefail
PYTHON="{python}"
ZIPAPP_DIR=$(mktemp -d)
trap "rm -rf $ZIPAPP_DIR" EXIT

while IFS='=' read -r src dst; do
    if [[ -f "$src" ]]; then
        mkdir -p "$ZIPAPP_DIR/$(dirname \"$dst\")"
        cp "$src" "$ZIPAPP_DIR/$dst"
    fi
done < {manifest}

"$PYTHON" -m zipapp "$ZIPAPP_DIR" -o "{output}" -p "{shebang}"
chmod +x "{output}"
""".format(
            python = python_bin,
            manifest = manifest_file.path,
            output = zipapp_file.path,
            shebang = ctx.attr.python_path or "/usr/bin/env python3",
        ),
        mnemonic = "PyZipapp",
        progress_message = "Creating zipapp %{output}",
    )

    # Wrapper script for bazel run
    executable = ctx.actions.declare_file(ctx.attr.name)
    ctx.actions.write(
        output = executable,
        content = """#!/bin/bash
# Wrapper for zipapp execution
exec "{python}" "{zipapp_path}" "$@"
""".format(
            python = ctx.attr.python_path or "python3",
            zipapp_path = zipapp_file.short_path,
        ),
        is_executable = True,
    )

    runfiles = ctx.runfiles(files = [zipapp_file, executable])

    return [
        DefaultInfo(
            files = depset([zipapp_file, executable]),
            executable = executable,
            runfiles = runfiles,
        ),
    ]

py_zipapp_binary = rule(
    implementation = _py_zipapp_binary_impl,
    attrs = {
        "main": attr.label(
            doc = "Main entry point Python file.",
            allow_single_file = [".py"],
            mandatory = True,
        ),
        "srcs": attr.label_list(
            doc = "Python source files to include in the zipapp.",
            allow_files = [".py"],
            default = [],
        ),
        "deps": attr.label_list(
            doc = "Dependencies to include in the zipapp.",
            default = [],
        ),
        "entry_point": attr.string(
            doc = """Python module path to use as the entry point.
            If not specified, derived from the main file path.
            Example: 'my_package.main' or 'django.core.management'.
            """,
            default = "",
        ),
        "python_path": attr.string(
            doc = "Shebang line for the zipapp interpreter.",
            default = "/usr/bin/env python3",
        ),
        "data": attr.label_list(
            doc = "Data files to include in the zipapp.",
            allow_files = True,
            default = [],
        ),
        "env": attr.string_dict(
            doc = "Environment variables to set at runtime.",
            default = {},
        ),
    },
    executable = True,
    toolchains = [PY_TOOLCHAIN],
    doc = """Build a self-contained Python zipapp executable.

This rule creates a .pyz file containing all Python sources and dependencies
that can be executed directly without requiring a virtualenv or Bazel.
Files are placed at their Bazel rlocation paths so that AspectPyInfo imports
resolve correctly.

Example usage:
    py_zipapp_binary(
        name = "my_app",
        main = "main.py",
        srcs = glob(["**/*.py"]),
        deps = ["//lib:my_lib"],
        entry_point = "my_package.main",
    )

The output can be run with:
    bazel run //:my_app
    # Or directly:
    python3 bazel-bin/my_app.pyz
""",
)
