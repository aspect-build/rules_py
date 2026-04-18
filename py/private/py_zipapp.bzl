"""Implementation for py_zipapp_binary rule.

Creates a self-contained Python zipapp executable that doesn't require a virtualenv.
This is a hermetic alternative to py_venv_binary that avoids symlink issues.
"""

load("@bazel_lib//lib:paths.bzl", "to_rlocation_path")
load("@rules_python//python:defs.bzl", "PyInfo")
load("//py/private:py_library.bzl", _py_library = "py_library_utils")
load("//py/private:py_semantics.bzl", _py_semantics = "semantics")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN")

# Template for the __main__.py that bootstraps the zipapp
_ZIPAPP_MAIN_PY = '''#!/usr/bin/env python3
"""Auto-generated __main__.py for zipapp execution."""

import sys
import os

# Add the zipapp's directory to Python path for imports
if __package__ is None:
    # Running as a script
    _zipapp_dir = os.path.dirname(__file__)
else:
    # Running as a module
    _zipapp_dir = os.path.dirname(os.path.abspath(__file__))

if _zipapp_dir not in sys.path:
    sys.path.insert(0, _zipapp_dir)

# Execute the entry point
if __name__ == "__main__":
    import runpy
    runpy.run_module("{entry_module}", run_name="__main__", alter_sys=True)
'''

def _py_zipapp_binary_impl(ctx):
    """Build a Python zipapp executable.

    Creates a .pyz file that contains all dependencies and can be executed
    directly with a Python interpreter.
    """
    py_toolchain = _py_semantics.resolve_toolchain(ctx)

    # Collect all transitive sources
    srcs_depset = _py_library.make_srcs_depset(ctx)
    virtual_resolution = _py_library.resolve_virtuals(ctx)

    # Build imports depset for path handling
    imports_depset = _py_library.make_imports_depset(ctx, extra_imports_depsets = virtual_resolution.imports)

    # Get the main entry point
    main_file = ctx.file.main
    if main_file == None:
        fail("main file must be specified")

    # Determine entry module from main file
    entry_path = main_file.path
    if entry_path.endswith(".py"):
        entry_module = entry_path[:-3].replace("/", ".").replace("\\", ".")
        # Remove leading dots that might come from workspace paths
        entry_module = entry_module.lstrip(".")
    else:
        entry_module = entry_path.replace("/", ".").replace("\\", ".")

    # Allow override via entry_point attribute
    if ctx.attr.entry_point:
        entry_module = ctx.attr.entry_point

    # Create __main__.py for the zipapp
    main_py = ctx.actions.declare_file("{}_zipapp_main.py".format(ctx.attr.name))
    ctx.actions.write(
        output = main_py,
        content = _ZIPAPP_MAIN_PY.format(
            entry_module = entry_module,
        ),
    )

    # Collect all input files for the zipapp
    all_inputs = depset(
        direct = [main_file, main_py],
        transitive = [
            srcs_depset,
            depset(ctx.files.deps),
        ] + virtual_resolution.srcs,
    ).to_list()

    # Create a mapping of files to their destination paths in the zipapp
    # We need to preserve the package structure for imports to work
    zipapp_file = ctx.actions.declare_file("{}.pyz".format(ctx.attr.name))

    # Use a shell command to create the zipapp structure
    # This is more reliable than trying to do complex file mapping in Starlark
    ctx.actions.run_shell(
        outputs = [zipapp_file],
        inputs = all_inputs,
        command = """
set -euo pipefail

# Create temporary directory for zipapp contents
ZIPAPP_DIR=$(mktemp -d)
trap "rm -rf $ZIPAPP_DIR" EXIT

# Copy all source files preserving directory structure
for src in {srcs}; do
    if [[ "$src" == *.py ]]; then
        # Determine destination based on path
        dest="$ZIPAPP_DIR/$(basename "$src")"
        # If it's in a package structure, preserve it
        if [[ "$src" == */* ]]; then
            # Try to maintain some directory structure for imports
            dir_part=$(dirname "$src")
            # Remove leading workspace/external repo parts
            clean_dir=$(echo "$dir_part" | sed 's|^external/[^/]*||' | sed 's|^||')
            if [[ -n "$clean_dir" ]]; then
                mkdir -p "$ZIPAPP_DIR/$clean_dir"
                dest="$ZIPAPP_DIR/$clean_dir/$(basename "$src")"
            fi
        fi
        cp "$src" "$dest"
    fi
done

# Copy dependencies preserving their structure
for dep in {deps}; do
    if [[ "$dep" == *.py ]] && [[ -f "$dep" ]]; then
        # For deps, we copy to root if not in a package
        cp "$dep" "$ZIPAPP_DIR/" 2>/dev/null || true
    fi
done

# Copy the main entry point
mkdir -p "$ZIPAPP_DIR/$(dirname {main_base})"
cp "{main_path}" "$ZIPAPP_DIR/{main_base}"

# Install the __main__.py
cp "{main_py_path}" "$ZIPAPP_DIR/__main__.py"

# Create the zipapp with the specified python path
python3 -m zipapp "$ZIPAPP_DIR" -o "{output}" -p "{python_path}"

# Make it executable
chmod +x "{output}"
""".format(
            srcs = " ".join([f.path for f in ctx.files.srcs]),
            deps = " ".join([f.path for f in ctx.files.deps]),
            main_path = main_file.path,
            main_base = main_file.basename,
            main_py_path = main_py.path,
            output = zipapp_file.path,
            python_path = ctx.attr.python_path or "/usr/bin/env python3",
        ),
        mnemonic = "PyZipapp",
        progress_message = "Creating zipapp %{output}",
    )

    # Create a wrapper script that can be used as the executable
    # This handles the case where we want to run with bazel run
    executable = ctx.actions.declare_file(ctx.attr.name)
    ctx.actions.write(
        output = executable,
        content = """#!/bin/bash
# Wrapper for zipapp execution
exec python3 "{zipapp_path}" "$@"
""".format(
            zipapp_path = zipapp_file.short_path,
        ),
        is_executable = True,
    )

    # Build runfiles
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
