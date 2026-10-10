"""Type checking for py_library, py_binary and py_test.

py_library and the venv behind each py_binary / py_test call
`type_check_action` to run ty, from the resolved type checker toolchain, over
the target's own sources, with its transitive dependencies visible as search
paths. A type error fails the build. Each target checks only its own sources,
so results cache per target.

The search paths are the execroot directories behind the target's import
roots (`PyInfo.import_dirs` and `PyInfo.pyi_import_dirs`), which each target
computes for its own files, so nothing is flattened at analysis time. Imports
from dependencies that carry only `@rules_python`'s `PyInfo` have no such
directories, so ty doesn't see them.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN", "TYPE_CHECKER_TOOLCHAIN")

TYPE_CHECK_ATTRS = {
    "type_check": attr.bool(
        doc = """Whether to type check this target's sources.

        Only takes effect when `--@aspect_rules_py//py:type_check` turns type
        checking on, which it is not by default. Type checking runs ty over
        this target's sources, and a type error fails the build.""",
        default = True,
    ),
    "_type_check_flag": attr.label(
        default = "//py/private/type_check:type_check_flag",
    ),
    "_type_check_config": attr.label(
        allow_files = True,
        default = "//py/private/type_check:config",
    ),
    "_type_check_empty_config": attr.label(
        allow_single_file = True,
        default = "//py/private/type_check:empty.ty.toml",
    ),
}

# Optional so targets keep analyzing without a checker; they go unchecked.
TYPE_CHECK_EXEC_GROUPS = {
    "type_check": exec_group(
        toolchains = [
            config_common.toolchain_type(TYPE_CHECKER_TOOLCHAIN, mandatory = False),
        ],
    ),
}

def _is_checkable(file):
    return file.extension in ("py", "pyi")

def _python_version(ctx):
    toolchain = ctx.toolchains[PY_TOOLCHAIN]
    py3 = getattr(toolchain, "py3_runtime", None) if toolchain else None
    vi = getattr(py3, "interpreter_version_info", None) if py3 else None
    if vi == None:
        return None
    return "{}.{}".format(vi.major, vi.minor)

def _dirname(file):
    return file.dirname or "."

def type_check_action(ctx, srcs, transitive_sources, transitive_pyi_files, import_dirs, pyi_import_dirs, srcs_on_path = False):
    """Declare the type check action for a target, if it should have one.

    Args:
        ctx: rule context. The rule must carry TYPE_CHECK_ATTRS and
            TYPE_CHECK_EXEC_GROUPS, and resolve PY_TOOLCHAIN (optionally).
        srcs: list[File], the target's own sources. Only `.py` and `.pyi`
            files are checked.
        transitive_sources: depset[File] of the runtime closure.
        transitive_pyi_files: depset[File] of the type-check-only closure.
        import_dirs: depset[str] of execroot directories for the import roots.
        pyi_import_dirs: depset[str] of execroot directories for the
            type-check-only import roots.
        srcs_on_path: whether each source's directory is a search path, as
            the script's directory is for `python main.py` and a test's is
            under pytest.

    Returns:
        depset[File] holding the check's output, an empty directory; empty
        when the target isn't checked.
    """
    srcs = [f for f in srcs if _is_checkable(f)]
    if (not srcs or
        not ctx.attr.type_check or
        not ctx.attr._type_check_flag[BuildSettingInfo].value or
        # Dependencies from other repositories are their owners' to check.
        ctx.label.workspace_name):
        return depset()

    toolchain = ctx.exec_groups["type_check"].toolchains[TYPE_CHECKER_TOOLCHAIN]
    if toolchain == None:
        return depset()
    checker = toolchain.type_checker
    ty = checker.checker.executable

    config_files = ctx.files._type_check_config
    if len(config_files) > 1:
        fail("--@aspect_rules_py//py:type_check_config must name a single file, got: {}".format(config_files))

    # Always pass a configuration file: it keeps ty from discovering a
    # ty.toml or pyproject.toml in the execroot or above it.
    config = config_files[0] if config_files else ctx.file._type_check_empty_config

    deps_inputs = depset(transitive = [transitive_sources, transitive_pyi_files])

    # A validation action must have an output, and ty writes none, so the
    # output is a directory that stays empty.
    out = ctx.actions.declare_directory(ctx.label.name + ".type_check")

    args = ctx.actions.args()
    args.use_param_file("@%s")
    args.set_param_file_format("multiline")
    args.add_all([
        "check",
        "--no-progress",
        "--output-format=concise",
        "--color=never",
        # Only errors fail the build.
        "--exit-zero-on-warning",
    ])

    # ty uses a .venv in the project directory as its environment. The
    # execroot, the default, can mirror one from the workspace, while ty's
    # own directory never has one.
    args.add("--project", ty.dirname)
    python_version = _python_version(ctx)
    if python_version:
        args.add("--python-version", python_version)
    args.add("--config-file", config)
    if srcs_on_path:
        args.add_all(srcs, map_each = _dirname, format_each = "--extra-search-path=%s", uniquify = True)

    # Type-check-only roots go first, so stubs from pyi_deps take precedence
    # over the runtime package they describe.
    args.add_all(pyi_import_dirs, format_each = "--extra-search-path=%s", uniquify = True)
    args.add_all(import_dirs, format_each = "--extra-search-path=%s", uniquify = True)
    args.add_all(srcs)

    ctx.actions.run(
        mnemonic = "PyTypeCheck",
        progress_message = "Type checking %{label}",
        executable = checker.checker,
        exec_group = "type_check",
        arguments = [args],
        # ty reads per-user configuration from here; point it nowhere.
        env = {"XDG_CONFIG_HOME": "/nonexistent"},
        inputs = depset(direct = srcs + [config], transitive = [deps_inputs]),
        outputs = [out],
    )
    return depset([out])
