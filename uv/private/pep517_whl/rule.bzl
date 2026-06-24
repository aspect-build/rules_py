"""
PEP 517 sdist-to-wheel build rules.

Uses `python -m build` (the pypa/build frontend) which delegates to whatever
build backend the sdist declares in its `[build-system]` table.
"""

load("@bazel_lib//lib:resource_sets.bzl", "resource_set", "resource_set_attr")
load("@bazel_tools//tools/cpp:toolchain_utils.bzl", "find_cpp_toolchain")
load("//py/private/toolchain:types.bzl", "NATIVE_BUILD_TOOLCHAIN", "PY_TOOLCHAIN")

_INHERITED_ENV_EXCLUSIONS = (
    "AR",
    "CC",
    "CPP",
    "CXX",
    "LD",
    "LDCXXSHARED",
    "LDSHARED",
    "MPICC",
    "PYTHONHOME",
    "PYTHONPATH",
    "PYTHONPLATLIBDIR",
    "STRIP",
)
_ENV_NAME_START = "ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz".elems()
_ENV_NAME_CHARS = _ENV_NAME_START + "0123456789".elems()

def _common_env(ctx):
    # pyproject_hooks copies the build process environment and launches its
    # Python executable without -I:
    # https://github.com/pypa/pyproject-hooks/blob/4b7c6d113fb89b755d762a88712c8a6873cddd47/src/pyproject_hooks/_impl.py#L70-L83
    # https://github.com/pypa/pyproject-hooks/blob/4b7c6d113fb89b755d762a88712c8a6873cddd47/src/pyproject_hooks/_impl.py#L378-L396
    # Host settings therefore must not replace that child's venv or stdlib.
    # https://docs.python.org/3/using/cmdline.html#environment-variables
    default_shell_env = {
        key: value
        for key, value in ctx.configuration.default_shell_env.items()
        if key.upper() not in _INHERITED_ENV_EXCLUSIONS
    }
    return {
        "SETUPTOOLS_SCM_PRETEND_VERSION": ctx.attr.version,
        # Determinism: fix hash seed so dict/set iteration order is stable
        "PYTHONHASHSEED": "0",
        # Determinism: reproducible timestamps in archives
        "SOURCE_DATE_EPOCH": "0",
    } | default_shell_env

def _patch_args_and_inputs(ctx):
    patch_args = []
    patch_inputs = []
    if ctx.attr.pre_build_patches:
        patch_args.extend(["--patch-strip", str(ctx.attr.pre_build_patch_strip)])
        for target in ctx.attr.pre_build_patches:
            for f in target[DefaultInfo].files.to_list():
                patch_args.extend(["--patch", f.path])
                patch_inputs.append(f)
    return patch_args, patch_inputs

def _memory_args(ctx):
    return ["--monitor-memory"] if ctx.attr.monitor_memory else []

def _collect_build_tool_info(ctx):
    """Gather files, executable tools, and Make variables from build tools.

    Each target passed via the rule's `toolchains`, `build_tools`, or
    `build_tool_env` attribute is inspected for providers:
      - DefaultInfo            -> files + default_runfiles added to action inputs
                                  and executable targets added as action tools
      - ToolchainInfo.all_files -> added to action inputs
      - TemplateVariableInfo   -> variables collected for `$(VAR)` expansion in
                                  `env` and `path_env`

    Pattern mirrors rules_rust's cargo_build_script
    (see cargo/private/cargo_build_script.bzl).
    """
    extra_inputs = []
    extra_tools = []
    materialized_tool_files = []
    known_variables = {}
    known_variable_owners = {}
    targets = {}
    for target in ctx.attr.toolchains:
        targets[str(target.label)] = target
    for target in ctx.attr.build_tools:
        targets[str(target.label)] = target
    for target in ctx.attr.build_tool_env:
        targets[str(target.label)] = target

    for target in targets.values():
        if DefaultInfo in target:
            default_info = target[DefaultInfo]
            extra_inputs.append(default_info.files)

            # `default_runfiles` can be None on some target types — guard it.
            default_runfiles = default_info.default_runfiles
            if default_runfiles:
                extra_inputs.append(default_runfiles.files)
            if default_info.files_to_run.executable:
                # FilesToRunProvider in `tools` causes Bazel to materialize the
                # executable's runfiles:
                # https://bazel.build/rules/lib/builtins/actions#run
                extra_tools.append(default_info.files_to_run)
                materialized_tool_files.append(default_info.files_to_run.executable)
        if platform_common.ToolchainInfo in target:
            all_files = getattr(target[platform_common.ToolchainInfo], "all_files", None)
            if all_files:
                if type(all_files) == "list":
                    all_files = depset(all_files)
                extra_inputs.append(all_files)
        if platform_common.TemplateVariableInfo in target:
            for name, value in target[platform_common.TemplateVariableInfo].variables.items():
                if name in known_variables and known_variables[name] != value:
                    fail((
                        "{}: build-tool targets {} and {} expose TemplateVariableInfo " +
                        "variable '{}' with different values: '{}' and '{}'"
                    ).format(
                        ctx.label,
                        known_variable_owners[name],
                        target.label,
                        name,
                        known_variables[name],
                        value,
                    ))
                if name not in known_variables:
                    known_variables[name] = value
                    known_variable_owners[name] = target.label

    build_tool_env_owners = {}
    for target, name in ctx.attr.build_tool_env.items():
        if (not name or name[0] not in _ENV_NAME_START or
            any([char not in _ENV_NAME_CHARS for char in name[1:].elems()])):
            fail("{}: build_tool_env value '{}' must match [A-Za-z_][A-Za-z0-9_]*".format(ctx.label, name))
        if name in build_tool_env_owners:
            fail("{}: build_tool_env targets {} and {} both assign '{}'".format(
                ctx.label,
                build_tool_env_owners[name],
                target.label,
                name,
            ))
        if DefaultInfo not in target:
            fail("{}: build_tool_env target {} has no DefaultInfo".format(ctx.label, target.label))

        default_info = target[DefaultInfo]
        executable = default_info.files_to_run.executable
        if executable:
            value = executable.path
        else:
            files = default_info.files.to_list()
            if len(files) != 1:
                fail("{}: non-executable build_tool_env target {} must produce exactly one file".format(ctx.label, target.label))
            value = files[0].path

        if name in known_variables and known_variables[name] != value:
            fail((
                "{}: build_tool_env target {} and {} expose variable '{}' " +
                "with different values: '{}' and '{}'"
            ).format(
                ctx.label,
                known_variable_owners[name],
                target.label,
                name,
                known_variables[name],
                value,
            ))
        if name not in known_variables:
            known_variables[name] = value
            known_variable_owners[name] = target.label
        build_tool_env_owners[name] = target.label
    return struct(
        inputs = extra_inputs,
        materialized_files = materialized_tool_files,
        tools = extra_tools,
        variables = known_variables,
    )

_BAZEL_CC_WRAPPER_BASENAMES = ["gcc", "g++", "clang", "clang++"]

def _cc_toolchain_inputs_and_compiler(ctx):
    """Return the C++ toolchain files and compiler path, when available."""
    cc_toolchain = find_cpp_toolchain(ctx)
    if not cc_toolchain or not hasattr(cc_toolchain, "all_files"):
        return None, None
    files = cc_toolchain.all_files
    compiler_file = None
    if hasattr(cc_toolchain, "compiler_executable"):
        compiler_basename = cc_toolchain.compiler_executable.split("/")[-1]
        for f in files.to_list():
            if f.basename == compiler_basename:
                compiler_file = f
                break
    if not compiler_file:
        for f in files.to_list():
            if f.basename in _BAZEL_CC_WRAPPER_BASENAMES:
                compiler_file = f
                break
    if not compiler_file:
        for f in files.to_list():
            if (f.basename.startswith("clang-") or f.basename.startswith("gcc-") or
                f.basename.startswith("g++-")):
                compiler_file = f
                break
    compiler_path = compiler_file.path if compiler_file else None
    return files, compiler_path

def _path_is_materialized(path_value, inputs):
    return any([
        path_value == f.path or
        (f.is_directory and path_value.startswith(f.path + "/")) or
        f.path.startswith(path_value + "/")
        for f in inputs
    ])

def _package_env(ctx, known_variables, build_tool_inputs, materialized_tool_files):
    build_tool_env_names = ctx.attr.build_tool_env.values()
    build_tool_overlap = sorted([name for name in build_tool_env_names if name in ctx.attr.env])
    if build_tool_overlap:
        fail("{}: build_tool_env and env keys overlap: {}".format(ctx.label, ", ".join(build_tool_overlap)))

    overlap = sorted([key for key in ctx.attr.env if key in ctx.attr.path_env])
    if overlap:
        fail("{}: env and path_env keys overlap: {}".format(ctx.label, ", ".join(overlap)))

    path_env = dict(ctx.attr.path_env)
    for name in build_tool_env_names:
        if name in path_env:
            fail("{}: build_tool_env and path_env keys overlap: {}".format(ctx.label, name))
        path_env[name] = "$({})".format(name)

    env = {}
    location_targets = ctx.attr.build_tools + ctx.attr.build_tool_env.keys()
    for key, value in ctx.attr.env.items():
        expanded = ctx.expand_location(value, targets = location_targets)
        env[key] = ctx.expand_make_variables("env", expanded, known_variables)

    input_files = depset(
        direct = materialized_tool_files,
        transitive = build_tool_inputs,
    ).to_list()
    absolutize_args = []
    for key, value in path_env.items():
        expanded = ctx.expand_location(value, targets = location_targets)
        expanded = ctx.expand_make_variables("path_env", expanded, known_variables)
        if not _path_is_materialized(expanded, input_files):
            fail((
                "{}: path_env value for '{}' expands to '{}', which is not " +
                "materialized by declared build tools"
            ).format(ctx.label, key, expanded))
        env[key] = expanded
        absolutize_args.extend(["--absolutize-env", key])
    return env, absolutize_args

def _build_action(ctx, mnemonic, progress_message, native = False):
    archive = ctx.file.src
    wheel_dir = ctx.actions.declare_directory("whl")
    patch_args, patch_inputs = _patch_args_and_inputs(ctx)
    build_tool_info = _collect_build_tool_info(ctx)
    env = _common_env(ctx)
    transitive_inputs = list(build_tool_info.inputs)
    if native:
        cc_files, cc_compiler = _cc_toolchain_inputs_and_compiler(ctx)
        if cc_files:
            transitive_inputs.append(cc_files)
        if cc_compiler:
            env["CC"] = cc_compiler
            env["CXX"] = cc_compiler
    package_env, path_env_args = _package_env(
        ctx,
        build_tool_info.variables,
        build_tool_info.inputs,
        build_tool_info.materialized_files,
    )
    env.update(package_env)
    compiler_args = ["--configure-compiler"] if native else []

    ctx.actions.run(
        mnemonic = mnemonic,
        progress_message = progress_message.format(archive.basename),
        executable = ctx.executable.tool,
        toolchain = None,
        arguments = ctx.attr.args + patch_args + _memory_args(ctx) + compiler_args + path_env_args + [
            archive.path,
            wheel_dir.path,
        ],
        inputs = depset(
            [archive] + patch_inputs,
            transitive = transitive_inputs,
        ),
        tools = [ctx.attr.tool[DefaultInfo].files_to_run] + build_tool_info.tools,
        outputs = [wheel_dir],
        env = env,
        exec_group = "target",
        resource_set = resource_set(ctx.attr),
    )

    return [DefaultInfo(files = depset([wheel_dir]))]

def _pep517_whl(ctx):
    return _build_action(
        ctx,
        "PySdistBuild",
        "Source compiling {} to a whl",
    )

def _pep517_native_whl(ctx):
    return _build_action(
        ctx,
        "PySdistNativeBuild",
        "Native source compiling {} to a whl",
        native = True,
    )

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

_pep517_whl_attrs = {
    "build_tool_env": attr.label_keyed_string_dict(
        cfg = config.exec("target"),
        doc = "Map executable or single-file build targets to path-valued environment variable names matching [A-Za-z_][A-Za-z0-9_]*.",
    ),
    "build_tools": attr.label_list(
        cfg = config.exec("target"),
        doc = "Build-tool targets analyzed for the wheel action's execution platform.",
    ),
    "env": attr.string_dict(
        doc = "Opaque environment values with locations and Make variables from build_tools.",
    ),
    "monitor_memory": attr.bool(
        default = False,
        doc = "Report approximate Linux process-tree RSS while building the wheel.",
    ),
    "path_env": attr.string_dict(
        doc = "Environment paths with locations and Make variables from build_tools.",
    ),
    "src": attr.label(allow_single_file = True),
    # The wheel action uses the named group below, so its frontend must use the
    # same execution platform:
    # https://bazel.build/extending/exec-groups#defining-exec-groups
    "tool": attr.label(executable = True, cfg = config.exec("target")),
    "version": attr.string(),
    "args": attr.string_list(default = ["--validate-anyarch"]),
} | _PATCH_ATTRS | resource_set_attr

pep517_whl = rule(
    implementation = _pep517_whl,
    doc = """PEP 517 sdist to anyarch whl build rule.

Consumes a sdist artifact and performs a build of that artifact with the
specified Python dependencies under the configured Python toolchain.

Build tools are explicit: `build_tools` contributes declared files, executable
runfiles, and Make variables. `build_tool_env` assigns an executable or
single-file target directly to a path-valued environment variable. `env`
selects opaque values passed to the backend, while `path_env` selects other
paths covered by declared inputs. Both string attributes support `$(location)`
references to build-tool targets; declared paths remain valid after the backend
changes directory.

""",
    attrs = _pep517_whl_attrs,
    exec_groups = {
        "target": exec_group(
            toolchains = [
                PY_TOOLCHAIN,
            ],
        ),
    },
)

pep517_native_whl = rule(
    implementation = _pep517_native_whl,
    doc = """PEP 517 sdist to platform-specific whl build rule.

Consumes a sdist artifact and performs a build of that artifact with the
specified Python dependencies under the configured Python toolchain to produce a
platform-specific bdist we can subsequently install or deploy.

Build tools are passed via `build_tools` or `build_tool_env`, and each target's
`DefaultInfo.files`, `DefaultInfo.default_runfiles`, `ToolchainInfo.all_files`,
and `TemplateVariableInfo.variables` are forwarded to the action. Executable
targets also contribute `DefaultInfo.files_to_run` as action tools. The `env`
attribute maps environment variable names to opaque strings that may reference
`$(location)` or `$(VAR)` expansions sourced from those targets. Native builds
infer `CC` and `CXX` from the configured C++ toolchain. Explicit
`build_tool_env`, `env`, and `path_env` declarations override those defaults.
`build_tool_env` variable names are also available as `$(VAR)` expansions in
`env` and `path_env`. Values that name declared input paths belong in
`path_env`, so they remain valid after the backend changes directory.

The build is guaranteed to occur on an execution platform matching the
constraints of the target platform.

""",
    attrs = _pep517_whl_attrs | {
        "args": attr.string_list(),
    },
    toolchains = [
        "@bazel_tools//tools/cpp:toolchain_type",
    ],
    exec_groups = {
        # Create an exec group which depends on a toolchain which can only be
        # resolved to exec_compatible_with constraints equal to the target. This
        # allows us to discover what those constraints need to be.
        #
        # NATIVE_BUILD_TOOLCHAIN has matching exec_compatible_with and
        # target_compatible_with, so this exec group only resolves when the exec
        # and target platforms match. Cross-compilation of sdists is intentionally
        # unsupported: PEP 517 build backends (setuptools, meson-python, etc.)
        # have no standard mechanism for cross-compilation, Python headers for
        # the target platform are not readily available, and output wheel tags
        # would need to encode the target platform with no upstream tooling
        # support. Packages that need cross-compiled native extensions should
        # publish pre-built wheels for their target platforms instead.
        "target": exec_group(
            toolchains = [
                PY_TOOLCHAIN,
                NATIVE_BUILD_TOOLCHAIN,
                "@bazel_tools//tools/cpp:toolchain_type",
            ],
        ),
    },
)
