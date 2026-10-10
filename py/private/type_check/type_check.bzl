"""Type checking for py_library, py_binary and py_test.

py_library and the venv behind each py_binary / py_test call
`type_check_action` to run the resolved type checker toolchain over the
target's own sources, with its transitive dependencies visible as search
paths. A type error fails the build. Each target checks only its own sources,
so results cache per target.

The search paths are the execroot directories behind the target's import
roots (`PyInfo.import_dirs` and `PyInfo.pyi_import_dirs`), which each target
computes for its own files. Import roots from providers that don't carry
those (`PyInfo.unmapped_imports`) are runfiles-relative, while the checker
runs in the execroot, where a root's files may sit under the source tree or
under any of the output roots its dependencies were built in. For those, the
runner script pairs the import root with every distinct root of the action's
inputs and keeps the directories that exist. Nothing is flattened at analysis
time.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//py/private/toolchain:types.bzl", "EXEC_TOOLS_TOOLCHAIN", "PY_TOOLCHAIN", "TYPE_CHECKER_TOOLCHAIN")

TYPE_CHECK_ATTRS = {
    "type_check": attr.bool(
        doc = """Whether to type check this target's sources.

        Only takes effect when `--@aspect_rules_py//py:type_check` turns type
        checking on, which it is not by default. Type checking runs the
        registered type checker toolchain (ty by default) over this target's
        sources, and a type error fails the build.""",
        default = True,
    ),
    "_type_check_flag": attr.label(
        default = "//py/private/type_check:type_check_flag",
    ),
    "_type_check_config": attr.label(
        allow_files = True,
        default = "//py/private/type_check:config",
    ),
    "_type_check_runner": attr.label(
        allow_single_file = True,
        default = "//py/private/type_check:run_checker.py",
    ),
}

# The checker and the interpreter that runs it must resolve on the same
# execution platform, so both live in one exec group. Optional so targets
# keep analyzing without them; type_check_action explains what's missing.
TYPE_CHECK_EXEC_GROUPS = {
    "type_check": exec_group(
        toolchains = [
            config_common.toolchain_type(TYPE_CHECKER_TOOLCHAIN, mandatory = False),
            config_common.toolchain_type(EXEC_TOOLS_TOOLCHAIN, mandatory = False),
        ],
    ),
}

def _is_checkable(file):
    return file.extension in ("py", "pyi")

def _input_root(file):
    return file.root.path or "."

def _python_version(ctx):
    toolchain = ctx.toolchains[PY_TOOLCHAIN]
    py3 = getattr(toolchain, "py3_runtime", None) if toolchain else None
    vi = getattr(py3, "interpreter_version_info", None) if py3 else None
    if vi == None:
        return None
    return "{}.{}".format(vi.major, vi.minor)

def _uses_python_prefix(checker):
    return any([
        "{empty_python_prefix}" in v
        for v in checker.args + checker.env.values()
    ])

def _dirname(file):
    return file.dirname or "."

def type_check_action(ctx, srcs, transitive_sources, transitive_pyi_files, import_dirs, pyi_import_dirs, unmapped_imports, srcs_on_path = False):
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
        unmapped_imports: depset[str] of runfiles-relative import roots whose
            execroot directories are unknown.
        srcs_on_path: whether each source's directory is a search path, as
            the script's directory is for `python main.py` and a test's is
            under pytest.

    Returns:
        depset[File] holding the check's log; empty when the target isn't
        checked.
    """
    srcs = [f for f in srcs if _is_checkable(f)]
    if (not srcs or
        not ctx.attr.type_check or
        not ctx.attr._type_check_flag[BuildSettingInfo].value or
        # Dependencies from other repositories are their owners' to check.
        ctx.label.workspace_name):
        return depset()

    toolchains = ctx.exec_groups["type_check"].toolchains
    toolchain = toolchains[TYPE_CHECKER_TOOLCHAIN]
    if toolchain == None:
        return depset()
    checker = toolchain.type_checker

    python_version = _python_version(ctx)
    if python_version == None and _uses_python_prefix(checker):
        # Without a version there's no prefix to build. A target without a
        # Python toolchain still analyzes, so it goes unchecked, as it would
        # without a checker toolchain.
        return depset()

    exec_toolchain = toolchains[EXEC_TOOLS_TOOLCHAIN]
    exec_runtime = exec_toolchain.exec_runtime if exec_toolchain else None
    if exec_runtime == None:
        fail(("{}: type checking runs under an exec-configuration Python interpreter, " +
              "but no `{}` toolchain was registered. Register rules_py's interpreters, " +
              "or turn type checking off with --@aspect_rules_py//py:type_check=false.").format(
            ctx.label,
            EXEC_TOOLS_TOOLCHAIN,
        ))

    config_files = ctx.files._type_check_config
    if len(config_files) > 1:
        fail("--@aspect_rules_py//py:type_check_config must name a single file, got: {}".format(config_files))
    config = config_files[0] if config_files else checker.config
    if config and not checker.config_flag:
        fail(("{}: --@aspect_rules_py//py:type_check_config is set, but the type checker " +
              "toolchain has no `config_flag` to pass it with.").format(ctx.label))

    deps_inputs = depset(transitive = [transitive_sources, transitive_pyi_files])
    log = ctx.actions.declare_file(ctx.label.name + ".type_check.log")

    args = ctx.actions.args()
    args.use_param_file("@%s")
    args.set_param_file_format("multiline")
    args.add("--output", log)
    args.add("--checker", checker.checker.executable)
    args.add("--workspace-name", ctx.workspace_name)
    if python_version:
        args.add("--python-version", python_version)
    if checker.python_version_flag:
        args.add("--python-version-flag=" + checker.python_version_flag)
    if config:
        args.add("--config", config)
        args.add("--config-flag=" + checker.config_flag)
    if checker.search_path_flag:
        args.add("--search-path-flag=" + checker.search_path_flag)
    else:
        args.add("--search-path-env", checker.search_path_env)
    args.add_all(["--env={}={}".format(k, v) for k, v in checker.env.items()])
    args.add_all(checker.args, format_each = "--arg=%s")
    if srcs_on_path:
        args.add_all(srcs, map_each = _dirname, format_each = "--path=%s", uniquify = True)

    # Type-check-only roots go first, so stubs from pyi_deps take precedence
    # over the runtime package they describe.
    args.add_all(pyi_import_dirs, format_each = "--path=%s", uniquify = True)
    args.add_all(import_dirs, format_each = "--path=%s", uniquify = True)
    args.add_all(unmapped_imports, format_each = "--import=%s", uniquify = True)

    # Tree artifacts count as one root each; expanding them would only repeat it.
    args.add_all(srcs, map_each = _input_root, format_each = "--root=%s", uniquify = True)
    args.add_all(deps_inputs, map_each = _input_root, format_each = "--root=%s", uniquify = True, expand_directories = False)
    args.add_all(srcs, format_each = "--src=%s")

    ctx.actions.run(
        mnemonic = "PyTypeCheck",
        progress_message = "Type checking %{label}",
        executable = exec_runtime.interpreter,
        exec_group = "type_check",
        arguments = [ctx.file._type_check_runner.path, args],
        inputs = depset(
            direct = srcs + [ctx.file._type_check_runner] + ([config] if config else []),
            transitive = [deps_inputs, checker.data, exec_runtime.files],
        ),
        tools = [checker.checker],
        outputs = [log],
    )
    return depset([log])
