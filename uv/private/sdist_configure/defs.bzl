"""Interface contract for sdist configure tools.

An sdist configure tool inspects a source distribution archive and reports
metadata used to generate the correct build targets for that package.

## Tool invocation

A configure tool is invoked as:

    <interpreter> <script> <archive-path> <context-json-path>

or, for compiled tools:

    <binary> <archive-path> <context-json-path>

Where:
- `archive-path` is the filesystem path to the sdist archive (.tar.gz, .zip, etc.)
- `context-json-path` is the filesystem path to a JSON file containing build
  context provided by the repository rule. See "Context input" below.

The tool MUST write a JSON object to stdout and exit 0 on success.
The tool SHOULD exit non-zero on failure. The repository rule will log
the tool's stderr and fall back to generating a default pure-Python build.

## Context input

The context JSON file contains information the tool may need to generate
build file content:

    {
        "src": <string>,          # Label string for the sdist source archive
        "version": <string>,      # Package version
        "deps": [<string>, ...],  # Labels of explicitly configured build deps
        "available_deps": {       # Mapping of normalized package names to labels
            <name>: <label>,      #   for all packages in the lockfile
            ...
        },
        "pre_build_patches": [<string>, ...],  # Patch file labels
        "pre_build_patch_strip": <int>         # Patch strip level
    }

    `available_deps` allows the tool to resolve additional build dependencies
    by normalized package name. Any package in the user's lockfile can be
    referenced here.

## JSON output schema

The JSON object MUST contain:

    {
        "is_native": <bool>
    }

    is_native: True if the archive contains source files that require a
    platform-specific build (C, C++, Cython, Fortran, Rust, assembly, etc.).
    When True and no `build_file_content` is provided, the repository rule
    generates an `sdist_native_build` target instead of `sdist_build`.

The JSON object MAY contain any of the following fields:

    "build_file_content": <string>

        Complete BUILD.bazel content. When present, the repository rule uses
        this verbatim instead of generating its own build file. This allows
        sophisticated configure tools to emit targets using arbitrary rule
        sets (rules_cc, rules_rs, etc.).

        The content MUST define a target named `whl` with
        visibility = ["//visibility:public"] that produces a wheel file.

    "extra_deps": [<string>, ...]

        Normalized package names of additional build-time dependencies
        discovered by the tool (e.g. from pyproject.toml [build-system]
        requires, or inferred from file extensions like .pyx -> cython).
        These are resolved against `available_deps` from the context and
        merged into the build target's deps. The repository rule will
        fail() if a name cannot be resolved.

    "native_files": [<string>, ...]

        Archive member paths that triggered `is_native`. Informational
        only; used for diagnostic logging.

    "build_requires": [<string>, ...]

        Normalized package names declared as build dependencies in config
        files (pyproject.toml, setup.cfg). Informational; used for logging.

    "inferred_build_requires": [<string>, ...]

        Normalized package names inferred from file extensions. Informational;
        used for logging.

## Default implementation

The bundled `detect_native.py` implements this contract. It requires
Python >= 3.11 (for `tomllib`). It is located at:

    @aspect_rules_py//uv/private/sdist_configure:detect_native.py
"""

# Default configure script bundled with rules_py.
DEFAULT_CONFIGURE_SCRIPT = Label("//uv/private/sdist_configure:detect_native.py")
