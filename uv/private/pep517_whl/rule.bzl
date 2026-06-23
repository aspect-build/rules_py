"""
PEP 517 sdist-to-wheel build rules.

Uses `python -m build` (the pypa/build frontend) which delegates to whatever
build backend the sdist declares in its `[build-system]` table.
"""

load("@bazel_lib//lib:resource_sets.bzl", "resource_set", "resource_set_attr")
load("//py/private/toolchain:types.bzl", "NATIVE_BUILD_TOOLCHAIN", "PY_TOOLCHAIN")
load(":providers.bzl", "BuiltWheelMetadataInfo")

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

def _built_wheel_metadata(ctx):
    if not (
        ctx.attr.built_wheel_metadata_declared or
        ctx.attr.built_wheel_console_scripts or
        ctx.attr.built_wheel_directory_top_levels or
        ctx.attr.built_wheel_top_levels
    ):
        return []

    invalid_directories = [
        name
        for name in ctx.attr.built_wheel_directory_top_levels
        if name not in ctx.attr.built_wheel_top_levels
    ]
    if invalid_directories:
        fail("{}: built_wheel_directory_top_levels entries are absent from built_wheel_top_levels: {}".format(
            ctx.label,
            invalid_directories,
        ))
    return [BuiltWheelMetadataInfo(
        console_scripts = tuple(ctx.attr.built_wheel_console_scripts),
        directory_top_levels = tuple(ctx.attr.built_wheel_directory_top_levels),
        origin = ctx.attr.built_wheel_metadata_origin or "PEP 517 rule attributes",
        top_levels = tuple(ctx.attr.built_wheel_top_levels),
    )]

def _collect_build_toolchain_inputs_and_vars(ctx):
    """Gather files and Make variables from `ctx.attr.build_toolchains`.

    Each target passed via the rule's `build_toolchains = [...]` attribute is
    inspected for providers:
      - DefaultInfo            -> files + default_runfiles added to action inputs
      - ToolchainInfo.all_files -> added to action inputs
      - TemplateVariableInfo   -> variables collected for `$(VAR)` expansion in `env`

    Pattern mirrors rules_rust's cargo_build_script
    (see cargo/private/cargo_build_script.bzl).
    """
    extra_inputs = []
    known_variables = {}
    known_variable_owners = {}
    for target in ctx.attr.build_toolchains:
        if DefaultInfo in target:
            extra_inputs.append(target[DefaultInfo].files)

            # `default_runfiles` can be None on some target types — guard it.
            default_runfiles = target[DefaultInfo].default_runfiles
            if default_runfiles:
                extra_inputs.append(default_runfiles.files)
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
                        "{}: build_toolchains {} and {} expose TemplateVariableInfo " +
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
    return extra_inputs, known_variables

def _path_is_materialized(path_value, inputs, allow_directory):
    return any([
        path_value == f.path or
        (f.is_directory and path_value.startswith(f.path + "/")) or
        (allow_directory and f.path.startswith(path_value + "/"))
        for f in inputs
    ])

def _package_env(ctx, known_variables, build_toolchain_inputs):
    """Expand package env and mark whole toolchain paths for cwd repair."""
    env = {}
    path_references = []
    for key, value in ctx.attr.env.items():
        expanded = ctx.expand_make_variables("env", value, known_variables)
        env[key] = expanded
        for variable in known_variables:
            if value != "$({})".format(variable):
                continue
            path_references.append((key, variable, expanded))
            break

    if not path_references:
        return env, []

    absolutize_args = []
    input_files = depset(transitive = build_toolchain_inputs).to_list()
    for key, variable, expanded in path_references:
        if not _path_is_materialized(expanded, input_files, True):
            fail((
                "{}: env value {} = $({}) expands to '{}', which is not " +
                "covered by files from the rule's build_toolchains attribute"
            ).format(ctx.label, key, variable, expanded))
        absolutize_args.extend(["--absolutize-toolchain-env", key])
    return env, absolutize_args

def _pep517_whl(ctx):
    archive = ctx.file.src
    wheel_dir = ctx.actions.declare_directory(ctx.label.name)
    patch_args, patch_inputs = _patch_args_and_inputs(ctx)
    extra_inputs, known_variables = _collect_build_toolchain_inputs_and_vars(ctx)
    env = _common_env(ctx)
    package_env, toolchain_env_args = _package_env(ctx, known_variables, extra_inputs)
    env.update(package_env)

    # The build tool is a py_binary wrapping build_helper.py. Using it as
    # a tool (not just an input) causes Bazel to materialize its runfiles in
    # the action sandbox, which means the venv shim can find the interpreter
    # via the standard runfiles mechanism regardless of whether the interpreter
    # comes from an external repo or the main workspace.
    ctx.actions.run(
        mnemonic = "PySdistBuild",
        progress_message = "Source compiling {} to a whl".format(archive.basename),
        executable = ctx.executable.tool,
        toolchain = None,
        arguments = ctx.attr.args + patch_args + toolchain_env_args + [
            archive.path,
            wheel_dir.path,
        ],
        inputs = depset(
            [archive] + patch_inputs,
            transitive = extra_inputs,
        ),
        tools = [ctx.attr.tool[DefaultInfo].files_to_run],
        outputs = [wheel_dir],
        env = env,
        exec_group = "target",
        resource_set = resource_set(ctx.attr),
    )

    return [DefaultInfo(files = depset([wheel_dir]))] + _built_wheel_metadata(ctx)

def _pep517_native_whl(ctx):
    archive = ctx.file.src
    wheel_dir = ctx.actions.declare_directory(ctx.label.name)
    patch_args, patch_inputs = _patch_args_and_inputs(ctx)

    env = _common_env(ctx)
    extra_inputs, known_variables = _collect_build_toolchain_inputs_and_vars(ctx)

    package_env, toolchain_env_args = _package_env(ctx, known_variables, extra_inputs)
    env.update(package_env)

    ctx.actions.run(
        mnemonic = "PySdistNativeBuild",
        progress_message = "Native source compiling {} to a whl".format(archive.basename),
        executable = ctx.executable.tool,
        toolchain = None,
        arguments = ctx.attr.args + patch_args + toolchain_env_args + [
            archive.path,
            wheel_dir.path,
        ],
        inputs = depset(
            [archive] + patch_inputs,
            transitive = extra_inputs,
        ),
        tools = [ctx.attr.tool[DefaultInfo].files_to_run],
        outputs = [wheel_dir],
        env = env,
        exec_group = "target",
        resource_set = resource_set(ctx.attr),
    )

    return [DefaultInfo(files = depset([wheel_dir]))] + _built_wheel_metadata(ctx)

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
    "build_toolchains": attr.label_list(
        cfg = config.exec("target"),
        doc = "Build-tool targets analyzed for the wheel-build action's execution platform. Their files become action inputs and their TemplateVariableInfo values are available to env.",
    ),
    "built_wheel_metadata_declared": attr.bool(
        doc = "Whether built-wheel metadata was explicitly declared, including an all-empty declaration.",
    ),
    "built_wheel_metadata_origin": attr.string(
        doc = "Human-readable declaration origin for execution-time mismatch diagnostics.",
    ),
    "built_wheel_console_scripts": attr.string_list(
        doc = "Complete console entry points in the built wheel, encoded as name=module:func.",
    ),
    "built_wheel_directory_top_levels": attr.string_list(
        doc = "Complete subset of built_wheel_top_levels installed as directories.",
    ),
    "built_wheel_top_levels": attr.string_list(
        doc = "Complete, configuration-invariant list of immediate site-packages entries when nonempty. Empty means the final layout is unknown.",
    ),
    "env": attr.string_dict(
        doc = "Environment variables to set on the build action. Values may " +
              "contain `$(VAR)` references to make-variables exposed by any " +
              "target in the rule's `build_toolchains` attribute (via " +
              "`TemplateVariableInfo`). An exact whole-value reference is " +
              "treated as an action-input path, validated against the " +
              "toolchain files, and made absolute before the backend changes " +
              "directory. Other values are not path-rewritten after " +
              "expansion.",
    ),
    "src": attr.label(allow_single_file = True),
    # The build actions use the target execution group, so their frontend must
    # be built for the same execution platform:
    # https://bazel.build/extending/exec-groups#defining-execution-groups
    "tool": attr.label(executable = True, cfg = config.exec("target")),
    "version": attr.string(),
    "args": attr.string_list(default = ["--validate-anyarch"]),
} | _PATCH_ATTRS | resource_set_attr

pep517_whl = rule(
    implementation = _pep517_whl,
    doc = """PEP 517 sdist to anyarch whl build rule.

Consumes a sdist artifact and performs a build of that artifact with the
specified Python dependencies under the configured Python toolchain.

Build-tool targets are passed via `build_toolchains` and analyzed for the
wheel-build action's execution platform. Each target's `DefaultInfo.files`,
`ToolchainInfo.all_files`, and `TemplateVariableInfo.variables` are forwarded
to the action. The `env`
attribute maps environment variable names to strings that may reference
`$(VAR)` make-variables sourced from those targets. Exact whole-value
references identify action-input paths that remain valid when the build helper
changes directory. Other strings are opaque and are not path-rewritten.

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

Build-tool targets are passed via `build_toolchains` and analyzed for the
wheel-build action's execution platform. Each target's `DefaultInfo.files`,
`ToolchainInfo.all_files`, and `TemplateVariableInfo.variables` are forwarded
to the action. The `env`
attribute maps environment variable names to strings that may reference
`$(VAR)` make-variables sourced from those targets. This mirrors the
pattern used by `rules_rust`'s `cargo_build_script`. Exact whole-value
references identify action-input paths that remain valid when the build helper
changes directory; other environment strings remain opaque.

Compiler commands are not inferred from `CcToolchainInfo`. Packages that need
a particular compiler must declare it in `env` and provide any required action
inputs through `build_toolchains`.

The build is guaranteed to occur on an execution platform matching the
constraints of the target platform.

""",
    attrs = _pep517_whl_attrs | {
        "args": attr.string_list(),
    },
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
            ],
        ),
    },
)
