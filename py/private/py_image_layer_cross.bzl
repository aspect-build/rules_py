"""Cross-platform support for py_image_layer.

This module provides support for building Linux container images on macOS
by downloading the appropriate Linux tools during the build process.
"""

def _get_linux_venv_tool(repository_ctx):
    """Download the Linux venv tool for cross-compilation."""
    
    # Determine which Linux tool to download based on target architecture
    # For now, assume linux_arm64 as that's what the user needs
    tool_name = "venv_aarch64_unknown_linux_musl"
    
    # URLs for the pre-built tools from rules_py releases
    version = "0.10.0"  # Should match the rules_py version
    base_url = "https://github.com/aspect-build/rules_py/releases/download/v{version}"
    url = base_url.format(version=version) + "/" + tool_name
    
    # Download the tool
    repository_ctx.download(
        url = url,
        output = "venv_linux",
        executable = True,
    )
    
    return "venv_linux"

def _cross_platform_venv_impl(ctx):
    """Create a venv that works on the target platform."""
    
    # For macOS building Linux images, we need the Linux venv tool
    # This is a simplified version - in production you'd detect the platforms
    
    venv_tool = ctx.file._venv_linux if ctx.attr.target_platform == "linux" else ctx.file._venv_tool
    
    venv_output = ctx.actions.declare_directory(ctx.attr.name + ".venv")
    
    ctx.actions.run(
        outputs = [venv_output],
        inputs = ctx.files.binary_runfiles + [venv_tool],
        executable = venv_tool,
        arguments = [
            "--location", venv_output.path,
            "--python", ctx.attr.python_path,
            "--pth-file", ctx.file.pth_file.path,
            "--collision-strategy", "ignore",
            "--venv-name", ".venv",
        ],
        mnemonic = "PyVenvCross",
        progress_message = "Creating cross-platform virtualenv for %s" % ctx.attr.name,
    )
    
    return [DefaultInfo(files = depset([venv_output]))]

cross_platform_venv = rule(
    implementation = _cross_platform_venv_impl,
    attrs = {
        "binary_runfiles": attr.label_list(allow_files = True),
        "pth_file": attr.label(allow_single_file = True),
        "python_path": attr.string(),
        "target_platform": attr.string(default = "linux"),
        "_venv_tool": attr.label(
            default = "@aspect_rules_py//py/tools/venv_bin:venv",
            allow_single_file = True,
            cfg = "exec",
        ),
        "_venv_linux": attr.label(
            default = "@rules_py_linux_tools//:venv",
            allow_single_file = True,
        ),
    },
)
