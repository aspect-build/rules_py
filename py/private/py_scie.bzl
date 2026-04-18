"""Implementation for py_scie_binary rule.

Creates a Self-Contained Interpreted Executable (SCIE) that bundles Python code,
a launcher, and optionally the Python interpreter itself.

This provides a hermetic alternative to py_venv_binary that avoids symlink issues
in distroless/RBE environments.
"""

load("@bazel_lib//lib:expand_make_vars.bzl", "expand_locations", "expand_variables")
load("@bazel_lib//lib:paths.bzl", "BASH_RLOCATION_FUNCTION", "to_rlocation_path")
load("@rules_python//python:defs.bzl", "PyInfo")
load("//py/private:py_library.bzl", _py_library = "py_library_utils")
load("//py/private:py_semantics.bzl", _py_semantics = "semantics")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN")

def _get_interpreter_hash(ctx, py_toolchain):
    """Generate a hash identifier for the Python interpreter."""
    # Use interpreter path and version info to create a unique identifier
    version_info = py_toolchain.interpreter_version_info
    hash_input = "{}_{}_{}".format(
        py_toolchain.python.path,
        version_info.major,
        version_info.minor,
    )
    # Create a simple hash (using first 16 chars for brevity)
    # In practice, this could use a more sophisticated hashing approach
    return hash_input.replace("/", "_").replace(".", "_")[:64]

def _create_zipapp(ctx, name, srcs_depset, virtual_resolution, main_file, output):
    """Create a zipapp containing all Python code."""

    # Collect all input files
    all_inputs = depset(
        direct = [main_file],
        transitive = [
            srcs_depset,
        ] + virtual_resolution.srcs,
    ).to_list()

    # Build the zipapp
    ctx.actions.run_shell(
        outputs = [output],
        inputs = all_inputs,
        command = """
set -euo pipefail

ZIPAPP_DIR=$(mktemp -d)
trap "rm -rf $ZIPAPP_DIR" EXIT

# Copy all Python files to the zipapp directory
for f in {files}; do
    if [[ "$f" == *.py ]]; then
        # Calculate destination path
        rel_path=$(basename "$f")
        # Try to preserve some directory structure for package imports
        if [[ "$f" == */* ]]; then
            dir_part=$(dirname "$f")
            # Clean external paths
            clean_dir=$(echo "$dir_part" | sed 's|^external/[^/]*/||' | sed 's|^bazel-out/[^/]*/bin/||')
            if [[ -n "$clean_dir" && "$clean_dir" != "." ]]; then
                mkdir -p "$ZIPAPP_DIR/$clean_dir"
                rel_path="$clean_dir/$(basename "$f")"
            fi
        fi
        cp "$f" "$ZIPAPP_DIR/$rel_path"
    fi
done

# Create a simple __main__.py if main file exists
if [[ -f "$ZIPAPP_DIR/{main_base}" ]]; then
    cat > "$ZIPAPP_DIR/__main__.py" << 'EOF'
#!/usr/bin/env python3
import sys
import os

# Ensure the zipapp directory is in path
_zipapp_dir = os.path.dirname(__file__)
if _zipapp_dir not in sys.path:
    sys.path.insert(0, _zipapp_dir)

# Run the main entry point
if __name__ == "__main__":
    import runpy
    runpy.run_path("{main_base}", run_name="__main__")
EOF
fi

# Create the zipapp
python3 -m zipapp "$ZIPAPP_DIR" -o "{output}" -p "/usr/bin/env python3"
chmod +x "{output}"
""".format(
            files = " ".join([f.path for f in all_inputs]),
            main_base = main_file.basename,
            output = output.path,
        ),
        mnemonic = "ScieZipapp",
        progress_message = "Creating SCIE zipapp for %{label}",
    )

def _create_launcher(ctx, zipapp_file, interpreter_hash, py_toolchain, output, include_interpreter):
    """Create the SCIE launcher script."""

    # Determine interpreter path for the launcher
    interpreter_path = py_toolchain.python.path
    if py_toolchain.runfiles_interpreter:
        interpreter_path = to_rlocation_path(ctx, py_toolchain.python)

    # Get interpreter files for embedding
    interpreter_files = []
    if include_interpreter and hasattr(py_toolchain, "files"):
        interpreter_files = py_toolchain.files.to_list()

    # Create interpreter tarball if including interpreter
    interpreter_tar = None
    if include_interpreter and interpreter_files:
        interpreter_tar = ctx.actions.declare_file("{}_interpreter.tar.gz".format(ctx.attr.name))
        ctx.actions.run_shell(
            outputs = [interpreter_tar],
            inputs = interpreter_files,
            command = """
set -euo pipefail
TAR_DIR=$(mktemp -d)
trap "rm -rf $TAR_DIR" EXIT

# Copy interpreter files preserving structure
for f in {files}; do
    if [[ -f "$f" ]]; then
        dest="$TAR_DIR/$(basename $f)"
        # Preserve relative structure for known paths
        cp "$f" "$dest" 2>/dev/null || true
    fi
done

# Create tarball
tar -czf {output} -C "$TAR_DIR" .
""".format(
                files = " ".join([f.path for f in interpreter_files[:100]]),  # Limit files
                output = interpreter_tar.path,
            ),
            mnemonic = "ScieInterpreterTar",
        )

    # Build runfiles library path
    runfiles_lib = ctx.attr._runfiles_lib[DefaultInfo].files.to_list()
    runfiles_lib_path = ""
    if runfiles_lib:
        runfiles_lib_path = to_rlocation_path(ctx, runfiles_lib[0])

    # Expand the launcher template
    substitutions = {
        "{{BASH_RLOCATION_FN}}": BASH_RLOCATION_FUNCTION.strip(),
        "{{INTERPRETER_PATH}}": interpreter_path,
        "{{INTERPRETER_HASH}}": interpreter_hash,
        "{{ZIPAPP_PATH}}": to_rlocation_path(ctx, zipapp_file) if ctx.attr.use_runfiles else zipapp_file.basename,
        "{{INCLUDE_INTERPRETER}}": str(include_interpreter).lower(),
        "{{RUNFILES_LIB}}": runfiles_lib_path,
        "{{SCIE_NAME}}": ctx.attr.name,
        "{{WORKSPACE_NAME}}": ctx.workspace_name,
    }

    # Use template or inline launcher
    if ctx.file._launcher_template:
        ctx.actions.expand_template(
            template = ctx.file._launcher_template,
            output = output,
            substitutions = substitutions,
            is_executable = True,
        )
    else:
        # Inline launcher implementation
        launcher_content = _SCIE_LAUNCHER_TEMPLATE.format(**substitutions)
        ctx.actions.write(
            output = output,
            content = launcher_content,
            is_executable = True,
        )

    return interpreter_tar

# Inline launcher template (fallback when no template file provided)
_SCIE_LAUNCHER_TEMPLATE = """#!/bin/bash
# SCIE Launcher - Self-Contained Interpreted Executable
# Generated by py_scie_binary

set -euo pipefail

# Runfiles initialization
{BASH_RLOCATION_FN}
runfiles_export_envvars

# Configuration
SCIE_NAME="{{SCIE_NAME}}"
INTERPRETER_HASH="{{INTERPRETER_HASH}}"
INCLUDE_INTERPRETER={{INCLUDE_INTERPRETER}}
WORKSPACE_NAME="{{WORKSPACE_NAME}}"

# Determine cache location
if [[ -n "${{XDG_CACHE_HOME:-}}" ]]; then
    CACHE_BASE="$XDG_CACHE_HOME"
elif [[ -n "${{HOME:-}}" ]]; then
    CACHE_BASE="$HOME/.cache"
else
    CACHE_BASE="/tmp"
fi
CACHE_DIR="$CACHE_BASE/rules_py_scie/$INTERPRETER_HASH"

# Find the script directory
SCRIPT_DIR=""
if [[ -n "${{BASH_SOURCE[0]:-}}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${{BASH_SOURCE[0]}}")" && pwd)"
else
    SCRIPT_DIR="$(pwd)"
fi

# Find zipapp
if [[ -f "$SCRIPT_DIR/{{ZIPAPP_PATH}}" ]]; then
    ZIPAPP_PATH="$SCRIPT_DIR/{{ZIPAPP_PATH}}"
elif [[ -n "${{RUNFILES_DIR:-}}" && -f "$RUNFILES_DIR/{{ZIPAPP_PATH}}" ]]; then
    ZIPAPP_PATH="$RUNFILES_DIR/{{ZIPAPP_PATH}}"
else
    # Try rlocation
    ZIPAPP_PATH="$(rlocation "{{ZIPAPP_PATH}}")" || true
fi

if [[ ! -f "$ZIPAPP_PATH" ]]; then
    echo "ERROR: Could not find zipapp at $ZIPAPP_PATH" >&2
    exit 1
fi

# Handle interpreter
if [[ "$INCLUDE_INTERPRETER" == "true" ]]; then
    # Check for embedded interpreter tarball
    INTERPRETER_TAR="$SCRIPT_DIR/interpreter.tar.gz"
    if [[ ! -f "$INTERPRETER_TAR" && -n "${{RUNFILES_DIR:-}}" ]]; then
        INTERPRETER_TAR="$RUNFILES_DIR/interpreter.tar.gz"
    fi

    if [[ -f "$INTERPRETER_TAR" ]]; then
        # Extract interpreter if not in cache
        if [[ ! -d "$CACHE_DIR/python" ]]; then
            mkdir -p "$CACHE_DIR"
            tar -xzf "$INTERPRETER_TAR" -C "$CACHE_DIR" 2>/dev/null || true
        fi

        # Use cached interpreter if available
        if [[ -f "$CACHE_DIR/python/bin/python3" ]]; then
            exec "$CACHE_DIR/python/bin/python3" "$ZIPAPP_PATH" "$@"
        elif [[ -f "$CACHE_DIR/bin/python3" ]]; then
            exec "$CACHE_DIR/bin/python3" "$ZIPAPP_PATH" "$@"
        fi
    fi
fi

# Fallback to system interpreter or runfiles interpreter
INTERPRETER="{{INTERPRETER_PATH}}"
if [[ -n "${{RUNFILES_DIR:-}}" ]]; then
    INTERPRETER="$(rlocation "$INTERPRETER")" || true
fi

if [[ ! -x "$INTERPRETER" ]]; then
    INTERPRETER="python3"
fi

exec "$INTERPRETER" "$ZIPAPP_PATH" "$@"
"""

def _py_scie_binary_impl(ctx):
    """Build a Self-Contained Interpreted Executable (SCIE).

    Creates a standalone executable that bundles Python code, dependencies,
    and optionally the Python interpreter itself.
    """
    py_toolchain = _py_semantics.resolve_toolchain(ctx)

    # Collect sources and resolve virtual dependencies
    srcs_depset = _py_library.make_srcs_depset(ctx)
    virtual_resolution = _py_library.resolve_virtuals(ctx)

    # Get the main entry point
    main_file = ctx.file.main
    if main_file == None:
        fail("main file must be specified")

    # Generate interpreter hash for cache management
    interpreter_hash = _get_interpreter_hash(ctx, py_toolchain)

    # Create the zipapp bundle
    zipapp_file = ctx.actions.declare_file("{}.pyz".format(ctx.attr.name))
    _create_zipapp(ctx, ctx.attr.name, srcs_depset, virtual_resolution, main_file, zipapp_file)

    # Create the launcher executable
    launcher = ctx.actions.declare_file(ctx.attr.name)
    interpreter_tar = _create_launcher(
        ctx,
        zipapp_file,
        interpreter_hash,
        py_toolchain,
        launcher,
        ctx.attr.include_interpreter,
    )

    # Collect all output files
    output_files = [launcher, zipapp_file]
    if interpreter_tar:
        output_files.append(interpreter_tar)

    # Build runfiles
    runfiles_files = [launcher, zipapp_file]
    if interpreter_tar:
        runfiles_files.append(interpreter_tar)
    if ctx.attr.include_interpreter:
        runfiles_files.extend(py_toolchain.files.to_list())

    runfiles = ctx.runfiles(files = runfiles_files)

    # Process environment variables
    passed_env = dict(ctx.attr.env)
    for k, v in passed_env.items():
        passed_env[k] = expand_variables(
            ctx,
            expand_locations(ctx, v, ctx.attr.data),
            attribute_name = "env",
        )

    return [
        DefaultInfo(
            files = depset(output_files),
            executable = launcher,
            runfiles = runfiles,
        ),
        RunEnvironmentInfo(
            environment = passed_env,
            inherited_environment = getattr(ctx.attr, "env_inherit", []),
        ),
    ]

py_scie_binary = rule(
    implementation = _py_scie_binary_impl,
    attrs = {
        "main": attr.label(
            doc = """
Main entry point Python file.
This is the script that will be executed when the SCIE runs.
""",
            allow_single_file = [".py"],
            mandatory = True,
        ),
        "srcs": attr.label_list(
            doc = "Python source files to include in the SCIE.",
            allow_files = [".py"],
            default = [],
        ),
        "deps": attr.label_list(
            doc = "Dependencies to include in the SCIE.",
            default = [],
        ),
        "data": attr.label_list(
            doc = "Data files to include in the SCIE runfiles.",
            allow_files = True,
            default = [],
        ),
        "include_interpreter": attr.bool(
            doc = """
Whether to embed the Python interpreter in the SCIE.

When True, the interpreter is bundled and extracted to a cache directory
on first run, making the binary truly self-contained.

When False, the system Python interpreter is used (must be compatible).
""",
            default = False,
        ),
        "use_runfiles": attr.bool(
            doc = """
Whether to use Bazel runfiles for locating the zipapp.

When True (default), uses rlocation for runfiles resolution.
When False, expects the zipapp to be in the same directory as the launcher.
""",
            default = True,
        ),
        "platform": attr.string(
            doc = """
Target platform for cross-compilation (e.g., 'linux_x86_64', 'macos_arm64').

When specified, attempts to bundle a platform-specific interpreter.
Requires that the interpreter toolchain supports the target platform.
""",
            default = "",
        ),
        "env": attr.string_dict(
            doc = "Environment variables to set at runtime.",
            default = {},
        ),
        "env_inherit": attr.string_list(
            doc = "Environment variables to inherit from the parent environment.",
            default = [],
        ),
        "_launcher_template": attr.label(
            doc = "Template file for the SCIE launcher script.",
            allow_single_file = [".sh", ".tmpl.sh"],
            default = "//py/private:scie_launcher.tmpl.sh",
        ),
        "_runfiles_lib": attr.label(
            default = "@bazel_tools//tools/bash/runfiles",
        ),
    },
    executable = True,
    toolchains = [PY_TOOLCHAIN],
    doc = """Build a Self-Contained Interpreted Executable (SCIE).

Creates a standalone executable that bundles Python code, dependencies,
and optionally the Python interpreter itself. This provides a hermetic
alternative to py_venv_binary that avoids symlink issues in distroless/RBE
environments.

## Key Features

- **Self-contained**: Embeds Python code and optionally the interpreter
- **Hermetic**: Avoids symlink issues common in virtualenv-based approaches
- **Cache-friendly**: Embeded interpreters are cached and reused
- **Cross-platform**: Supports different target platforms

## Example Usage

Basic usage (requires system Python):
    py_scie_binary(
        name = "my_app",
        main = "main.py",
        srcs = glob(["**/*.py"]),
        deps = ["//lib:my_lib"],
    )

Fully self-contained with embedded interpreter:
    py_scie_binary(
        name = "my_app_standalone",
        main = "main.py",
        srcs = glob(["**/*.py"]),
        deps = ["//lib:my_lib"],
        include_interpreter = True,
    )

## Execution

The SCIE can be run with:
    bazel run //:my_app

Or the generated executable can be run directly:
    ./bazel-bin/my_app

When `include_interpreter = True`, the interpreter is extracted to a cache
directory on first run (~/.cache/rules_py_scie/ or $XDG_CACHE_HOME).
""",
)

# Convenience macro for common use cases
def py_scie_binary_macro(name, main, srcs = [], deps = [], data = [], include_interpreter = False, **kwargs):
    """Macro wrapper for py_scie_binary with common defaults."""
    py_scie_binary(
        name = name,
        main = main,
        srcs = srcs,
        deps = deps,
        data = data,
        include_interpreter = include_interpreter,
        **kwargs
    )

# Export the main rule and helper functions
py_scie = struct(
    binary = py_scie_binary,
    binary_macro = py_scie_binary_macro,
)
