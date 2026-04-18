"""Cross-platform Python binary rule for container images.

This rule creates a Python binary that bundles a Linux Python interpreter
for cross-compilation support when building on macOS for Linux containers.
"""

load("//py/private:py_library.bzl", "py_library_utils")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN")

# Linux Python standalone builds for cross-compilation
# From https://github.com/indygreg/python-build-standalone
LINUX_PYTHON_URLS = {
    "3.11": {
        "aarch64": "https://github.com/indygreg/python-build-standalone/releases/download/20250106/cpython-3.11.11+20250106-aarch64-unknown-linux-gnu-install_only.tar.gz",
        "x86_64": "https://github.com/indygreg/python-build-standalone/releases/download/20250106/cpython-3.11.11+20250106-x86_64-unknown-linux-gnu-install_only.tar.gz",
    },
    "3.10": {
        "aarch64": "https://github.com/indygreg/python-build-standalone/releases/download/20250106/cpython-3.10.16+20250106-aarch64-unknown-linux-gnu-install_only.tar.gz",
        "x86_64": "https://github.com/indygreg/python-build-standalone/releases/download/20250106/cpython-3.10.16+20250106-x86_64-unknown-linux-gnu-install_only.tar.gz",
    },
    "3.12": {
        "aarch64": "https://github.com/indygreg/python-build-standalone/releases/download/20250106/cpython-3.12.8+20250106-aarch64-unknown-linux-gnu-install_only.tar.gz",
        "x86_64": "https://github.com/indygreg/python-build-standalone/releases/download/20250106/cpython-3.12.8+20250106-x86_64-unknown-linux-gnu-install_only.tar.gz",
    },
}

_UV_PLATFORM_MAP = {
    "aarch64": "manylinux_2_31_aarch64",
    "x86_64": "manylinux_2_31_x86_64",
}

def _get_python_version_str(py_toolchain):
    """Get Python version string (e.g., '3.11') from toolchain."""
    py_runtime = py_toolchain.py3_runtime
    if not py_runtime:
        fail("Python 3 runtime not found in toolchain")
    info = py_runtime.interpreter_version_info
    return "{}.{}".format(info.major, info.minor)

def _py_container_binary_impl(ctx):
    """Implementation of py_container_binary rule."""
    py_toolchain = ctx.toolchains[PY_TOOLCHAIN]
    
    # Get the virtual environment resolution using py_library_utils
    virtual_resolution = py_library_utils.resolve_virtuals(ctx, ignore_missing = True)
    
    # Get Python version for lock file
    py_version = _get_python_version_str(py_toolchain)
    
    # Determine main entry point
    if ctx.attr.main:
        main_file = ctx.file.main
    elif ctx.files.srcs:
        # If no main specified, use the first src
        main_file = ctx.files.srcs[0]
    else:
        fail("Either 'main' or 'srcs' must be specified")
    
    # Download Linux Python interpreter for cross-compilation
    linux_python_tar = ctx.actions.declare_file("{}_linux_python.tar.gz".format(ctx.attr.name))
    
    linux_python_url = LINUX_PYTHON_URLS.get(py_version, {}).get(ctx.attr.target_cpu)
    if not linux_python_url:
        fail("No Linux Python available for version {} and CPU {}".format(py_version, ctx.attr.target_cpu))
    
    ctx.actions.run_shell(
        outputs = [linux_python_tar],
        command = "curl -L -o {out} {url}".format(
            out = linux_python_tar.path,
            url = linux_python_url,
        ),
        progress_message = "Downloading Linux Python {} for {}".format(py_version, ctx.attr.name),
        mnemonic = "DownloadLinuxPython",
        execution_requirements = {
            "requires-network": "1",
            "no-sandbox": "1",
        },
    )
    
    # Extract Linux Python
    linux_python_dir = ctx.actions.declare_directory("{}_linux_python".format(ctx.attr.name))
    ctx.actions.run_shell(
        outputs = [linux_python_dir],
        inputs = [linux_python_tar],
        command = "mkdir -p {out} && tar -xzf {tar} -C {out} --strip-components=1".format(
            out = linux_python_dir.path,
            tar = linux_python_tar.path,
        ),
        progress_message = "Extracting Linux Python interpreter for %s" % ctx.attr.name,
        mnemonic = "ExtractLinuxPython",
    )

    linux_packages_dir = ctx.actions.declare_directory("{}_linux_packages".format(ctx.attr.name))
    uv = ctx.executable._uv
    pip_platform = _UV_PLATFORM_MAP.get(ctx.attr.target_cpu, "manylinux_2_31_" + ctx.attr.target_cpu)
    
    install_commands = []
    for pkg_spec in ctx.attr.linux_packages:
        pkg_name = pkg_spec.split("==")[0].strip()
        norm_name = pkg_name.replace("-", "_").lower()
        install_commands.append('echo "Installing {pkg_spec} for Linux {cpu}..."'.format(pkg_spec = pkg_spec, cpu = ctx.attr.target_cpu))
        install_commands.append('mkdir -p "{out_dir}/{norm_name}"'.format(out_dir = linux_packages_dir.path, norm_name = norm_name))
        install_commands.append('"{uv}" pip install --python-platform linux --python-version {py_version} --target "{out_dir}/{norm_name}" --no-deps "{pkg_spec}" || echo "Warning: failed to install {pkg_spec}"'.format(
            uv = uv.path,
            py_version = py_version,
            out_dir = linux_packages_dir.path,
            norm_name = norm_name,
            pkg_spec = pkg_spec,
        ))
        install_commands.append('touch "{out_dir}/{norm_name}/.downloaded"'.format(out_dir = linux_packages_dir.path, norm_name = norm_name))
    
    if install_commands:
        full_command = " && ".join(install_commands)
    else:
        full_command = "mkdir -p {out} && touch {out}/.done".format(out = linux_packages_dir.path)
    
    ctx.actions.run_shell(
        outputs = [linux_packages_dir],
        command = full_command,
        tools = [uv],
        progress_message = "Installing Linux packages for %s" % ctx.attr.name,
        mnemonic = "InstallLinuxPackages",
        execution_requirements = {
            "requires-network": "1",
            "no-sandbox": "1",
        },
    )
    
    runfiles_depsets = [
        py_library_utils.make_srcs_depset(ctx),
    ] + virtual_resolution.srcs + virtual_resolution.runfiles
    
    all_runfiles = depset(transitive = runfiles_depsets).to_list()
    
    imports_depset = py_library_utils.make_imports_depset(ctx, extra_imports_depsets = virtual_resolution.imports)
    import_paths = imports_depset.to_list()
    
    launcher = ctx.actions.declare_file("{}.sh".format(ctx.attr.name))
    
    env_exports = []
    for k, v in ctx.attr.env.items():
        env_exports.append('export {}="{}"'.format(k, v))
    env_exports.append('export BAZEL_TARGET="{}"'.format(str(ctx.label).lstrip("@")))
    env_exports.append('export BAZEL_WORKSPACE="{}"'.format(ctx.workspace_name))
    env_exports.append('export BAZEL_TARGET_NAME="{}"'.format(ctx.attr.name))
    
    python_major = py_toolchain.py3_runtime.interpreter_version_info.major
    
    import_lines = "\n".join(['        echo "$RUNFILES_DIR/{}"'.format(p) for p in import_paths])
    
    launcher_content = '''#!/usr/bin/env sh
# Container launcher for {name}
# Uses bundled Linux Python interpreter for cross-platform compatibility

set -e

# Find the script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Find runfiles directory
RUNFILES_DIR="${{SCRIPT_DIR}}.runfiles"
if [ ! -d "$RUNFILES_DIR" ]; then
    RUNFILES_DIR="${{SCRIPT_DIR}}/{name}.runfiles"
fi
if [ ! -d "$RUNFILES_DIR" ]; then
    RUNFILES_DIR=$(find "$SCRIPT_DIR" -maxdepth 1 -name "*.runfiles" -type d | head -1)
fi

# Find the Linux Python installation
LINUX_PYTHON_DIR="$RUNFILES_DIR/{workspace}/{linux_python_dir_path}"
if [ ! -d "$LINUX_PYTHON_DIR" ]; then
    LINUX_PYTHON_DIR="$RUNFILES_DIR/{linux_python_dir_path}"
fi

# Set up Python environment
export PYTHONHOME="$LINUX_PYTHON_DIR"
export PYTHONPATH="$LINUX_PYTHON_DIR/lib/python{py_version}.zip:$LINUX_PYTHON_DIR/lib/python{py_version}:$LINUX_PYTHON_DIR/lib/python{py_version}/lib-dynload:$LINUX_PYTHON_DIR/lib/python{py_version}/site-packages"
export PATH="$LINUX_PYTHON_DIR/bin:$PATH"

# Use the bundled Python
PYTHON="$LINUX_PYTHON_DIR/bin/python{python_major}"

# Find the entry point module
ENTRY_POINT="$RUNFILES_DIR/{workspace}/{entry_point_path}"
if [ ! -f "$ENTRY_POINT" ]; then
    ENTRY_POINT="$RUNFILES_DIR/{entry_point_path}"
fi
if [ ! -f "$ENTRY_POINT" ]; then
    echo "ERROR: Could not find entry point at $ENTRY_POINT" >&2
    exit 1
fi

# Set up site-packages with dependencies
SITE_PACKAGES="$LINUX_PYTHON_DIR/lib/python{py_version}/site-packages"

# Create a .pth file with absolute paths to all dependencies
PTH_FILE="$SITE_PACKAGES/container_deps.pth"

# Collect all dependency paths for the .pth file
{{
    # Bazel first-party import paths (same as py_binary)
{import_lines}

    # Graph-based extension: packages are under aspect_rules_py++uv+whl_install__*
    for dep_dir in "$RUNFILES_DIR"/aspect_rules_py++uv+whl_install__*; do
        if [ -d "$dep_dir" ]; then
            find "$dep_dir" -type d -name "site-packages" 2>/dev/null
        fi
    done

    # Legacy extension: packages under aspect_rules_py++uv+pystar/*
    for dep_dir in "$RUNFILES_DIR"/aspect_rules_py++uv+pystar/*; do
        if [ -d "$dep_dir" ]; then
            echo "$dep_dir"
        fi
    done

    # Add Linux packages if they exist
    LINUX_PKGS_DIR="$RUNFILES_DIR/{workspace}/{linux_packages_dir_path}"
    if [ -d "$LINUX_PKGS_DIR" ]; then
        for pkg_dir in "$LINUX_PKGS_DIR"/*; do
            if [ -d "$pkg_dir" ] && [ -f "$pkg_dir/.downloaded" ]; then
                if [ -d "$pkg_dir/site-packages" ]; then
                    echo "$pkg_dir/site-packages"
                else
                    echo "$pkg_dir"
                fi
            fi
        done
    fi
}} | sort -u > "$PTH_FILE"

# Set default environment
{env_exports}

export PYTHONUNBUFFERED=1

# Execute with the bundled Python
exec "$PYTHON" "$ENTRY_POINT" "$@"
'''.format(
        name = ctx.attr.name,
        workspace = ctx.workspace_name,
        entry_point_path = main_file.short_path,
        linux_python_dir_path = linux_python_dir.short_path,
        linux_packages_dir_path = linux_packages_dir.short_path,
        python_major = python_major,
        py_version = py_version,
        import_lines = import_lines,
        env_exports = "\n".join(env_exports),
    )
    
    ctx.actions.write(
        output = launcher,
        content = launcher_content,
        is_executable = True,
    )
    
    # Collect all data files
    data_files = []
    for target in ctx.attr.data:
        data_files.extend(target.files.to_list())
    
    # Create runfiles for the launcher
    runfiles = ctx.runfiles(
        files = all_runfiles + [linux_python_dir, linux_packages_dir] + ctx.files.srcs + data_files,
    )
    
    # Add transitive runfiles from deps and data
    for target in ctx.attr.deps + ctx.attr.data:
        runfiles = runfiles.merge(target[DefaultInfo].default_runfiles)
    
    return [DefaultInfo(
        files = depset([launcher]),
        runfiles = runfiles,
        executable = launcher,
    )]

py_container_binary = rule(
    implementation = _py_container_binary_impl,
    attrs = {
        "srcs": attr.label_list(
            doc = "Python source files",
            allow_files = True,
        ),
        "main": attr.label(
            doc = "Main entry point Python file",
            allow_single_file = True,
        ),
        "deps": attr.label_list(
            doc = "Python dependencies",
            providers = [[]],
        ),
        "data": attr.label_list(
            doc = "Runtime data dependencies",
            allow_files = True,
        ),
        "env": attr.string_dict(
            doc = "Environment variables to set at runtime",
            default = {},
        ),
        "extra_pth": attr.label_list(
            doc = "Additional paths to add to Python path",
            allow_files = True,
        ),

        "target_cpu": attr.string(
            doc = "Target CPU architecture for cross-compilation",
            default = "aarch64",
            values = ["aarch64", "x86_64"],
        ),
        "linux_packages": attr.string_list(
            doc = "List of package names that need Linux-specific wheels",
            default = [],
        ),
        "package_collisions": attr.string(
            doc = "How to handle package name collisions (ignore/warn/error)",
            default = "warn",
            values = ["ignore", "warn", "error"],
        ),
        "resolutions": attr.label_keyed_string_dict(
            doc = """Satisfy a virtual_dep with a mapping from external package name to the label of an installed package that provides it.""",
            default = {},
        ),
        "_uv": attr.label(
            default = "@uv//:uv",
            allow_single_file = True,
            executable = True,
            cfg = "exec",
        ),
    },
    toolchains = [PY_TOOLCHAIN],
    executable = True,
)
