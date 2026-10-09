"""The `py_type_checker_toolchain` rule.

A type checker toolchain tells rules_py how to invoke a checker over one
target's sources. py_library, py_binary and py_test run it when type
checking is on (see //py/private/type_check:type_check.bzl), so a type error
fails the build.

The checker's command line is assembled from declarative attributes rather
than a fixed contract, so ty and mypy both plug in without an adapter. A
checker whose CLI can't be described this way can be wrapped in a small binary
that accepts these conventions.
"""

PyTypeCheckerInfo = provider(
    doc = "How to invoke a Python type checker. Carried as `ToolchainInfo.type_checker`.",
    fields = {
        "checker": "FilesToRunProvider: the checker executable (exec configuration).",
        "data": "depset[File]: extra files the checker reads.",
        "config": "File | None: the default configuration file.",
        "config_flag": "str: flag preceding the configuration file, e.g. `--config-file`.",
        "args": "list[str]: arguments placed before the generated ones. See the rule docs for placeholders.",
        "env": "dict[str, str]: environment variables. Placeholders are substituted as in `args`.",
        "python_version_flag": "str: flag preceding the `X.Y` target Python version, or empty to omit it.",
        "search_path_flag": "str: flag preceding each import search path, or empty.",
        "search_path_env": "str: environment variable receiving all search paths joined by the OS path separator, or empty.",
    },
)

_TYPE_CHECK_FLAG = "//py/private/type_check:type_check_flag"

def _type_check_off_impl(_settings, _attr):
    return {_TYPE_CHECK_FLAG: False}

# A checker built from Python targets, such as a py_binary running mypy, would
# otherwise have its own venv resolve this toolchain, which depends on that
# venv. With the flag off, toolchains gated on //py:type_check_enabled don't
# resolve for the checker's dependencies.
_type_check_off = transition(
    implementation = _type_check_off_impl,
    inputs = [],
    outputs = [_TYPE_CHECK_FLAG],
)

def _py_type_checker_toolchain_impl(ctx):
    if bool(ctx.attr.search_path_flag) == bool(ctx.attr.search_path_env):
        fail("{}: set exactly one of `search_path_flag` and `search_path_env`.".format(ctx.label))
    if ctx.file.config and not ctx.attr.config_flag:
        fail("{}: `config` is set, so `config_flag` must name the flag that passes it.".format(ctx.label))

    return [platform_common.ToolchainInfo(
        type_checker = PyTypeCheckerInfo(
            checker = ctx.attr.checker[DefaultInfo].files_to_run,
            data = depset(ctx.files.data),
            config = ctx.file.config,
            config_flag = ctx.attr.config_flag,
            args = ctx.attr.args,
            env = ctx.attr.env,
            python_version_flag = ctx.attr.python_version_flag,
            search_path_flag = ctx.attr.search_path_flag,
            search_path_env = ctx.attr.search_path_env,
        ),
    )]

py_type_checker_toolchain = rule(
    implementation = _py_type_checker_toolchain_impl,
    cfg = _type_check_off,
    doc = """Defines a Python type checker for rules_py's type checking.

For each py_library, py_binary and py_test with sources, rules_py runs

    <checker> <args> [<python_version_flag> X.Y] [<config_flag> <config>]
              [<search_path_flag> <path>]... <srcs>...

The checker must exit non-zero when it finds a type error. Its output appears
in the build log on failure.

Two placeholders are substituted in `args` and `env` values:

* `{scratch}`: an empty directory private to this invocation.
* `{empty_python_prefix}`: a directory laid out as a Python installation for
  the target version, with an empty `site-packages`. Point the checker's
  interpreter or environment option at it, so it doesn't fall back to the
  host's site-packages.

Register the toolchain with `register_toolchains` in your root MODULE.bazel,
which takes precedence over the default ty toolchain:

```starlark
py_type_checker_toolchain(
    name = "mypy_impl",
    checker = ":mypy",
    args = ["--no-error-summary", "--cache-dir={scratch}"],
    python_version_flag = "--python-version",
    config = "//:mypy.ini",
    config_flag = "--config-file",
    search_path_env = "MYPYPATH",
)

toolchain(
    name = "mypy",
    # Keeps the toolchain from resolving for mypy's own py_binary.
    target_settings = ["@aspect_rules_py//py:type_check_enabled"],
    toolchain = ":mypy_impl",
    toolchain_type = "@aspect_rules_py//py:type_checker_toolchain_type",
)
```
""",
    attrs = {
        "checker": attr.label(
            doc = "The type checker executable.",
            mandatory = True,
            executable = True,
            allow_files = True,
            cfg = "exec",
        ),
        "data": attr.label_list(
            doc = "Extra files the checker reads at run time.",
            allow_files = True,
            cfg = "exec",
        ),
        "config": attr.label(
            doc = """Default configuration file.

            `--@aspect_rules_py//py:type_check_config` overrides it.""",
            allow_single_file = True,
        ),
        "config_flag": attr.string(
            doc = "Flag preceding the configuration file.",
        ),
        "args": attr.string_list(
            doc = "Arguments placed before the generated ones.",
        ),
        "env": attr.string_dict(
            doc = "Environment variables for the checker.",
        ),
        "python_version_flag": attr.string(
            doc = "Flag preceding the target `X.Y` Python version. Empty omits it.",
        ),
        "search_path_flag": attr.string(
            doc = "Flag preceding each import search path, e.g. `--extra-search-path`.",
        ),
        "search_path_env": attr.string(
            doc = "Environment variable receiving the search paths, e.g. `MYPYPATH`.",
        ),
    },
)
