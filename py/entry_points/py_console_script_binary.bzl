"""Macro to generate py_binary targets for console scripts.

This module provides py_console_script_binary, a macro that generates
a py_binary target from a package's console_scripts entry point.

Example usage:
    load("//py/entry_points:py_console_script_binary.bzl", "py_console_script_binary")
    
    py_console_script_binary(
        name = "black",
        pkg = "@pypi__black//:lib",
    )
"""

# Import py_binary from private module to avoid circular dependency with py/defs.bzl
load("//py/private:py_binary.bzl", _py_binary = "py_binary")
load(":py_console_script_gen.bzl", "py_console_script_gen")

def _dist_info(pkg):
    """Get the dist_info target for a package.

    Args:
        pkg: A label string or Label object pointing to the package

    Returns:
        A label pointing to the dist_info target
    """
    if type(pkg) == type(""):
        label = native.package_relative_label(pkg)
    else:
        label = pkg

    if hasattr(label, "same_package_label"):
        return label.same_package_label("dist_info")
    else:
        return label.relative("dist_info")

def py_console_script_binary(
        *,
        name,
        pkg,
        script = None,
        main = None,
        **kwargs):
    """Generate a py_binary for a console_script entry point.

    This macro creates a py_binary target that invokes a console script
    from an installed Python package. It reads the entry_points.txt
    from the package's dist-info to find the entry point specification.

    Args:
        name: Name of the target to create
        pkg: Label of the package (e.g., "@pypi__black//:lib")
        script: Name of the console script (defaults to target name)
        main: Name of the generated entry point file (defaults to <name>_main.py)
        **kwargs: Additional arguments passed to py_binary

    Example:
        py_console_script_binary(
            name = "black",
            pkg = "@pypi__black//:lib",
        )

        # Creates a target //:black that runs the black formatter
    """
    main = main or name + "_main.py"

    if kwargs.pop("srcs", None):
        fail("py_console_script_binary does not accept 'srcs' - srcs are generated automatically")

    # Generate the entry point Python file
    dist_info_target = _dist_info(pkg)
    py_console_script_gen(
        name = name + "_gen",
        entry_points_txt = dist_info_target,
        dist_info = dist_info_target,
        console_script = script or "",
        console_script_guess = name,
        out = main,
        python_version = kwargs.get("python_version", ""),
        venv = kwargs.get("venv", ""),
        visibility = ["//visibility:private"],
    )

    # Create the py_binary using the generated main file
    # Include dist_info as data so metadata files (METADATA, WHEEL, RECORD, etc.)
    # are available in runfiles for proper package introspection
    _py_binary(
        name = name,
        srcs = [main],
        main = main,
        deps = [pkg] + kwargs.pop("deps", []),
        data = [_dist_info(pkg)] + kwargs.pop("data", []),
        **kwargs
    )
