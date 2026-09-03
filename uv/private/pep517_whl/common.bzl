"""Shared helpers and attrs for the PEP 517 sdist-to-wheel rules."""

load("@bazel_lib//lib:resource_sets.bzl", "resource_set_attr")
load("//uv/private:source_built_wheel.bzl", "SourceBuiltWheelInfo")

TARGET_EXEC_GROUP = "target"

_INHERITED_PYTHON_ENV = (
    "PYTHONHOME",
    "PYTHONPATH",
    "PYTHONPLATLIBDIR",
)

def wheel_providers(wheel_file, console_scripts):
    return [
        DefaultInfo(files = depset([wheel_file])),
        SourceBuiltWheelInfo(console_scripts = tuple(console_scripts)),
    ]

def common_env(ctx):
    # pyproject_hooks copies the build process environment and launches its
    # Python executable without -I:
    # https://github.com/pypa/pyproject-hooks/blob/4b7c6d113fb89b755d762a88712c8a6873cddd47/src/pyproject_hooks/_impl.py#L70-L83
    # https://github.com/pypa/pyproject-hooks/blob/4b7c6d113fb89b755d762a88712c8a6873cddd47/src/pyproject_hooks/_impl.py#L378-L396
    # Host settings therefore must not replace that child's venv or stdlib.
    # https://docs.python.org/3/using/cmdline.html#environment-variables
    default_shell_env = {
        key: value
        for key, value in ctx.configuration.default_shell_env.items()
        if key.upper() not in _INHERITED_PYTHON_ENV
    }
    return {
        "SETUPTOOLS_SCM_PRETEND_VERSION": ctx.attr.version,
        # Determinism: fix hash seed so dict/set iteration order is stable
        "PYTHONHASHSEED": "0",
        # Determinism: reproducible timestamps in archives
        "SOURCE_DATE_EPOCH": "0",
    } | default_shell_env

def patch_args_and_inputs(ctx):
    patch_args = ctx.actions.args()
    patch_inputs = []
    if ctx.attr.pre_build_patches:
        patch_args.add("--patch-strip", str(ctx.attr.pre_build_patch_strip))
        for target in ctx.attr.pre_build_patches:
            files = target[DefaultInfo].files
            patch_args.add_all(files, before_each = "--patch")
            patch_inputs.append(files)
    return patch_args, depset(transitive = patch_inputs)

def memory_args(ctx):
    return ["--monitor-memory"] if ctx.attr.monitor_memory else []

def config_setting_args(ctx):
    """`--config-setting key=value` per listed value, keys sorted for a stable action key."""
    args = []
    for key in sorted(ctx.attr.config_settings):
        for value in ctx.attr.config_settings[key]:
            args += ["--config-setting", "{}={}".format(key, value)]
    return args

_PATCH_ATTRS = {
    "pre_build_patches": attr.label_list(
        default = [],
        allow_files = [".patch", ".diff"],
        doc = "Patch files to apply to the extracted source before building.",
    ),
    "pre_build_patch_strip": attr.int(
        default = 0,
        doc = "Strip count for pre-build patches (-p flag to patch).",
    ),
}

PEP517_WHL_ATTRS = {
    "src": attr.label(allow_single_file = True),
    # The wheel action uses the named group below, so its frontend must use the
    # same execution platform:
    # https://bazel.build/extending/exec-groups#defining-exec-groups
    "tool": attr.label(executable = True, cfg = config.exec(TARGET_EXEC_GROUP)),
    "version": attr.string(),
    "console_scripts": attr.string_list(
        doc = "Console scripts discovered from the source distribution's entry-point metadata.",
    ),
    "args": attr.string_list(default = ["--validate-anyarch"]),
    "config_settings": attr.string_list_dict(
        default = {},
        doc = "PEP 517 config settings passed to the build frontend as `-C key=value`, one per listed value; repeated keys reach the backend as a list.",
    ),
    "monitor_memory": attr.bool(
        default = False,
        doc = "Report approximate Linux process-tree RSS while building the wheel.",
    ),
} | _PATCH_ATTRS | resource_set_attr
