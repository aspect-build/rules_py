"""Implementation for py_scie_binary rule.

Creates a Self-Contained Interpreted Executable (SCIE) that bundles Python code,
a launcher, and optionally the Python interpreter itself.

This provides a hermetic alternative to py_venv_binary that avoids symlink issues
in distroless/RBE environments. The zipapp preserves Bazel runfiles paths and
injects AspectPyInfo import paths for correct module resolution.
"""

load("@bazel_lib//lib:expand_make_vars.bzl", "expand_locations", "expand_variables")
load("@bazel_lib//lib:paths.bzl", "BASH_RLOCATION_FUNCTION", "to_rlocation_path")
load("//py/private:py_library.bzl", _py_library = "py_library_utils")
load("//py/private:py_semantics.bzl", _py_semantics = "semantics")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN")

def _create_zipapp(ctx, name, srcs_depset, virtual_resolution, imports_depset, main_file, output, py_toolchain):
    """Create a zipapp containing all Python code at their rlocation paths."""

    manifest_entries = []
    seen_dst = {}

    def _add_file(file):
        dst = to_rlocation_path(ctx, file)
        if dst not in seen_dst:
            seen_dst[dst] = True
            manifest_entries.append("{}={}".format(file.path, dst))

    for f in srcs_depset.to_list():
        _add_file(f)
    for dep in virtual_resolution.srcs:
        for f in dep.to_list():
            _add_file(f)

    _add_file(main_file)

    # Generate __main__.py that injects AspectPyInfo imports into sys.path
    imports_list = imports_depset.to_list()
    main_py = ctx.actions.declare_file("{}_scie_main.py".format(name))
    ctx.actions.write(
        output = main_py,
        content = """#!/usr/bin/env python3
import sys, os
_zipapp = sys.path[0]
_IMPORTS = {imports!r}
for _imp in _IMPORTS:
    _path = os.path.join(_zipapp, _imp)
    if _path not in sys.path:
        sys.path.append(_path)
import runpy
runpy.run_path("{entrypoint}", run_name="__main__")
""".format(
            imports = imports_list,
            entrypoint = to_rlocation_path(ctx, main_file),
        ),
    )
    manifest_entries.append("{}={}".format(main_py.path, "__main__.py"))

    manifest_file = ctx.actions.declare_file("{}.scie.manifest".format(name))
    ctx.actions.write(manifest_file, "\n".join(manifest_entries))

    python_bin = py_toolchain.python.path
    if py_toolchain.runfiles_interpreter:
        python_bin = to_rlocation_path(ctx, py_toolchain.python)

    ctx.actions.run_shell(
        outputs = [output],
        inputs = srcs_depset.to_list() + [main_file, main_py, manifest_file] + [f for dep in virtual_resolution.srcs for f in dep.to_list()],
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

"$PYTHON" -m zipapp "$ZIPAPP_DIR" -o "{output}" -p "/usr/bin/env python3"
chmod +x "{output}"
""".format(
            python = python_bin,
            manifest = manifest_file.path,
            output = output.path,
        ),
        mnemonic = "ScieZipapp",
        progress_message = "Creating SCIE zipapp for %{label}",
    )

def _create_launcher(ctx, zipapp_file, py_toolchain, imports_depset, output, include_interpreter):
    """Create the SCIE launcher script."""

    interpreter_path = py_toolchain.python.path
    if py_toolchain.runfiles_interpreter:
        interpreter_path = to_rlocation_path(ctx, py_toolchain.python)

    # Pass imports as colon-separated string for PYTHONPATH injection in launcher
    imports_list = imports_depset.to_list()
    imports_str = ":".join(imports_list)

    substitutions = {
        "{{BASH_RLOCATION_FN}}": BASH_RLOCATION_FUNCTION.strip(),
        "{{INTERPRETER_PATH}}": interpreter_path,
        "{{ZIPAPP_PATH}}": to_rlocation_path(ctx, zipapp_file) if ctx.attr.use_runfiles else zipapp_file.basename,
        "{{INCLUDE_INTERPRETER}}": str(include_interpreter).lower(),
        "{{SCIE_NAME}}": ctx.attr.name,
        "{{WORKSPACE_NAME}}": ctx.workspace_name,
        "{{IMPORTS}}": imports_str,
    }

    if ctx.file._launcher_template:
        ctx.actions.expand_template(
            template = ctx.file._launcher_template,
            output = output,
            substitutions = substitutions,
            is_executable = True,
        )
    else:
        fail("No launcher template provided")

def _py_scie_binary_impl(ctx):
    """Build a Self-Contained Interpreted Executable (SCIE)."""
    py_toolchain = _py_semantics.resolve_toolchain(ctx)

    srcs_depset = _py_library.make_srcs_depset(ctx)
    virtual_resolution = _py_library.resolve_virtuals(ctx)
    imports_depset = _py_library.make_imports_depset(ctx, extra_imports_depsets = virtual_resolution.imports)

    main_file = ctx.file.main
    if main_file == None:
        fail("main file must be specified")

    zipapp_file = ctx.actions.declare_file("{}.pyz".format(ctx.attr.name))
    _create_zipapp(ctx, ctx.attr.name, srcs_depset, virtual_resolution, imports_depset, main_file, zipapp_file, py_toolchain)

    launcher = ctx.actions.declare_file(ctx.attr.name)
    _create_launcher(
        ctx,
        zipapp_file,
        py_toolchain,
        imports_depset,
        launcher,
        ctx.attr.include_interpreter,
    )

    output_files = [launcher, zipapp_file]

    runfiles_files = [launcher, zipapp_file]
    if ctx.attr.include_interpreter:
        runfiles_files.extend(py_toolchain.files.to_list())

    runfiles = ctx.runfiles(files = runfiles_files)

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
Whether to include the Python interpreter runfiles in the SCIE.

When True, the interpreter toolchain files are added to the runfiles,
allowing the launcher to resolve the hermetic interpreter via rlocation.
This increases self-containment but still requires a compatible runtime
environment.

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

The zipapp preserves Bazel runfiles paths and injects AspectPyInfo imports
at startup for correct module resolution.

## Key Features

- **Self-contained**: Embeds Python code and optionally the interpreter
- **Hermetic**: Avoids symlink issues common in virtualenv-based approaches
- **Deterministic**: Uses Bazel toolchain interpreter for zipapp creation
- **Import-preserving**: AspectPyInfo imports are injected into sys.path

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

When `include_interpreter = True`, the interpreter files are included in
runfiles and resolved via Bazel rlocation.
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
