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

The context JSON file contains information the tool may use when inspecting
the archive:

    {
        "src": <string>,          # Label string for the sdist source archive
        "version": <string>,      # Package version
        "deps": [<string>, ...],  # Labels of explicitly configured build deps
        "available_deps": {       # Mapping of normalized package names to labels
            <name>: <label>,      #   for all packages in the lockfile
            ...
        }
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
    platform-specific build (C, C++, Cython, Rust, assembly, etc.).
    When True, the repository rule generates a `pep517_native_whl` target
    instead of `pep517_whl`.

The JSON object MAY contain any of the following fields:

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

    "console_scripts": [<string>, ...]

        Complete console-script entry points discovered from the source
        distribution, encoded as `name=module:object`. These are forwarded to
        the generated wheel target so venv assembly can create wrappers.
        When `build_file_content` is present, the custom BUILD content owns
        attaching this metadata; an explicit console-script override remains
        available for source producers that cannot expose it.

## Default implementation

The bundled `detect_native.py` implements this contract. It requires
Python >= 3.11 (for `tomllib`). It is located at:

    @aspect_rules_py//uv/private/sdist_configure:detect_native.py
"""

# Default configure script bundled with rules_py.
DEFAULT_CONFIGURE_SCRIPT = Label("//uv/private/sdist_configure:detect_native.py")
