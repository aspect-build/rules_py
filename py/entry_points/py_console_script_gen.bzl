"""Rule to generate console script entry point files.

This module provides a Bazel rule that generates Python entry point files
from entry_points.txt metadata, similar to rules_python but simplified
for use with our UV-based system.
"""

def _get_entry_points_txt(entry_points_txt):
    """Get the entry_points.txt file from the input target.

    Supports both direct file targets and TreeArtifacts (directories)
    by returning the first file/directory provided.
    """
    files = entry_points_txt.files.to_list()
    for file in files:
        if file.basename == "entry_points.txt":
            return file
    # Fallback for TreeArtifacts: return the directory and let the Python
    # script search inside it at action execution time.
    if files:
        return files[0]
    fail("{} does not contain any files".format(entry_points_txt))

def _get_dist_info_dir(dist_info_target):
    """Get the dist-info directory basename for importlib_metadata support.

    Args:
        dist_info_target: The dist_info filegroup target

    Returns:
        The basename of the dist-info directory (e.g., "flake8-7.1.1.dist-info")
    """
    for file in dist_info_target.files.to_list():
        # Look for a file inside the dist-info directory
        if ".dist-info" in file.basename:
            # Return the directory name (e.g., "flake8-7.1.1.dist-info")
            return file.basename
        elif ".dist-info/" in file.path:
            # Extract the dist-info directory name from the path
            parts = file.path.split("/")
            for i, part in enumerate(parts):
                if ".dist-info" in part:
                    return part
    return ""

def _py_console_script_gen_impl(ctx):
    entry_points_txt = _get_entry_points_txt(ctx.attr.entry_points_txt)

    args = ctx.actions.args()
    # Use .path to support TreeArtifacts (directories) which cannot be added
    # directly via args.add() due to Bazel's multi-value expansion rules.
    args.add(entry_points_txt.path)
    args.add(ctx.outputs.out)

    if ctx.attr.console_script:
        args.add("--console-script", ctx.attr.console_script)

    if ctx.attr.console_script_guess:
        args.add("--console-script-guess", ctx.attr.console_script_guess)

    # Add dist-info directory path if provided
    if ctx.attr.dist_info:
        dist_info_dir = _get_dist_info_dir(ctx.attr.dist_info)
        if dist_info_dir:
            args.add("--dist-info-dir", dist_info_dir)

    ctx.actions.run(
        inputs = [entry_points_txt] + ctx.files.dist_info,
        outputs = [ctx.outputs.out],
        arguments = [args],
        mnemonic = "PyConsoleScriptGen",
        progress_message = "Generating console script: %{label}",
        executable = ctx.executable._generator,
    )

    return [DefaultInfo(files = depset([ctx.outputs.out]))]

py_console_script_gen = rule(
    implementation = _py_console_script_gen_impl,
    attrs = {
        "entry_points_txt": attr.label(
            doc = "Target containing entry_points.txt file",
            mandatory = True,
            allow_files = True,
        ),
        "console_script": attr.string(
            doc = "Name of console script to generate (auto-detected if not provided)",
            default = "",
        ),
        "console_script_guess": attr.string(
            doc = "Guess for console script name when auto-detecting",
            default = "",
        ),
        "out": attr.output(
            doc = "Output file name",
            mandatory = True,
        ),
        "dist_info": attr.label(
            doc = "Target containing the package's dist-info directory (for importlib_metadata support)",
            allow_files = True,
            default = None,
        ),
        "_generator": attr.label(
            doc = "Generator script executable",
            default = "//py/entry_points:py_console_script_gen",
            executable = True,
            cfg = "exec",
        ),
    },
    doc = "Generates a Python entry point file from entry_points.txt",
)
