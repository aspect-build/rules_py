"""
PEP 517 sdist-to-wheel build rules.

Uses `python -m build` (the pypa/build frontend) which delegates to whatever
build backend the sdist declares in its `[build-system]` table.
"""

load("@bazel_lib//lib:resource_sets.bzl", "resource_set_for")
load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load("//py/private/toolchain:types.bzl", "NATIVE_BUILD_TOOLCHAIN", "PY_TOOLCHAIN")
load(":providers.bzl", "BuiltWheelMetadataInfo")

_CC_TOOLCHAIN_TYPE = "@bazel_tools//tools/cpp:toolchain_type"

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
        if key.upper() not in ("PYTHONHOME", "PYTHONPATH", "PYTHONPLATLIBDIR")
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
    if ctx.attr.built_wheel_console_scripts and not ctx.attr.built_wheel_top_levels:
        fail("{}: built_wheel_console_scripts requires complete built_wheel_top_levels metadata".format(ctx.label))
    if not ctx.attr.built_wheel_top_levels:
        return []
    return [BuiltWheelMetadataInfo(
        console_scripts = tuple(ctx.attr.built_wheel_console_scripts),
        directory_top_levels = tuple(ctx.attr.built_wheel_directory_top_levels),
        top_levels = tuple(ctx.attr.built_wheel_top_levels),
    )]

def _collect_toolchain_inputs_and_vars(ctx):
    """Gather files + Make-variable substitutions from `ctx.attr.toolchains`.

    Each target passed via the rule's `toolchains = [...]` attribute is
    inspected for providers:
      - DefaultInfo            -> files + default_runfiles added to action inputs
      - ToolchainInfo.all_files -> added to action inputs
      - TemplateVariableInfo   -> variables collected for `$(VAR)` expansion in `env`

    Pattern mirrors rules_rust's cargo_build_script
    (see cargo/private/cargo_build_script.bzl).
    """
    extra_inputs = []
    known_variables = {}
    for target in ctx.attr.toolchains:
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
            known_variables.update(target[platform_common.TemplateVariableInfo].variables)
    return extra_inputs, known_variables

def _cc_action(feature_configuration, action_name, variables):
    return struct(
        command = [cc_common.get_tool_for_action(
            action_name = action_name,
            feature_configuration = feature_configuration,
        )] + cc_common.get_memory_inefficient_command_line(
            action_name = action_name,
            feature_configuration = feature_configuration,
            variables = variables,
        ),
        environment = cc_common.get_environment_variables(
            action_name = action_name,
            feature_configuration = feature_configuration,
            variables = variables,
        ),
    )

def _cc_toolchain_inputs_and_commands(ctx):
    """Return the target exec group's C++ inputs and compiler commands."""
    toolchain = ctx.exec_groups["target"].toolchains[_CC_TOOLCHAIN_TYPE]
    cc_toolchain = toolchain.cc if hasattr(toolchain, "cc_provider_in_toolchain") else toolchain
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )
    compile_variables = cc_common.create_compile_variables(
        cc_toolchain = cc_toolchain,
        feature_configuration = feature_configuration,
        use_pic = True,
    )

    # A configured compiler action is a command, not merely an executable.
    # Preserve flags selected by the toolchain, including target and sysroot.
    # Python's compiler abstraction supplies the platform-specific extension
    # linker flags and replaces only their compiler driver for C++ targets:
    # https://github.com/pypa/setuptools/blob/84ed5913724df5a12dc804e1d5efe12508e706d2/setuptools/_distutils/sysconfig.py#L306-L373
    # https://github.com/pypa/setuptools/blob/84ed5913724df5a12dc804e1d5efe12508e706d2/setuptools/_distutils/compilers/C/unix.py#L285-L305
    # Bazel's generic dynamic-library action has different semantics, notably
    # `-shared` instead of `-bundle` on macOS.
    # https://bazel.build/rules/lib/toplevel/cc_common#get_memory_inefficient_command_line
    cc_action = _cc_action(
        feature_configuration,
        ACTION_NAMES.c_compile,
        compile_variables,
    )
    cxx_action = _cc_action(
        feature_configuration,
        ACTION_NAMES.cpp_compile,
        compile_variables,
    )
    commands = {
        "CC": cc_action.command,
        "CXX": cxx_action.command,
    }
    if (commands["CC"][0] == commands["CXX"][0] and
        cc_action.environment == cxx_action.environment and not any([
        argument.startswith("--driver-mode=")
        for argument in commands["CXX"][1:]
    ])):
        if cc_toolchain.compiler == "clang":
            # A shared Clang entry point otherwise links C++ extensions as C.
            # https://clang.llvm.org/docs/UsersManual.html#cmdoption-driver-mode
            commands["CXX"].insert(1, "--driver-mode=g++")
    environments = {
        "CC": cc_action.environment,
        "CXX": cxx_action.environment,
    }

    candidate_roots = {}
    all_files = cc_toolchain.all_files
    for file in all_files.to_list():
        parts = file.path.split("/")
        if parts[0] == "external" and len(parts) >= 2:
            candidate = "/".join(parts[:2])
        elif parts[0] == "bazel-out" and len(parts) >= 3:
            candidate = "/".join(parts[:3])
        elif len(parts) >= 2:
            candidate = "/".join(parts[:2])
        else:
            candidate = file.path
        candidate_roots[candidate] = True
    return all_files, {
        "commands": commands,
        "environments": environments,
        # The helper changes cwd before invoking the compiler. Supplying the
        # small deduplicated set of all toolchain roots lets it relocate every
        # occurrence in commands and environment values without duplicating
        # path-token parsing in Starlark.
        "input_roots": sorted(candidate_roots.keys(), key = len, reverse = True),
    }

def _pep517_whl(ctx):
    archive = ctx.file.src
    wheel_dir = ctx.actions.declare_directory(ctx.label.name)
    patch_args, patch_inputs = _patch_args_and_inputs(ctx)

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
        arguments = ctx.attr.args + patch_args + [
            archive.path,
            wheel_dir.path,
        ],
        inputs = [archive] + patch_inputs,
        tools = [ctx.attr.tool[DefaultInfo].files_to_run],
        outputs = [wheel_dir],
        env = _common_env(ctx),
        exec_group = "target",
        resource_set = resource_set_for(mem_mb = ctx.attr.build_memory_mb),
    )

    return [DefaultInfo(files = depset([wheel_dir]))] + _built_wheel_metadata(ctx)

def _pep517_native_whl(ctx):
    archive = ctx.file.src
    wheel_dir = ctx.actions.declare_directory(ctx.label.name)
    patch_args, patch_inputs = _patch_args_and_inputs(ctx)

    env = _common_env(ctx)
    extra_inputs, known_variables = _collect_toolchain_inputs_and_vars(ctx)

    cc_files, compiler_config = _cc_toolchain_inputs_and_commands(ctx)
    extra_inputs.append(cc_files)

    # Package overrides belong in this rule's env attribute. Do not let an
    # ambient shell compiler replace the configured target toolchain.
    for key in ["CC", "CXX", "CPP", "LDSHARED", "LDCXXSHARED", "MPICC"]:
        env.pop(key, None)
    for k, v in ctx.attr.env.items():
        env[k] = ctx.expand_make_variables("env", v, known_variables)

    ctx.actions.run(
        mnemonic = "PySdistNativeBuild",
        progress_message = "Native source compiling {} to a whl".format(archive.basename),
        executable = ctx.executable.tool,
        toolchain = None,
        arguments = ctx.attr.args + patch_args + [
            "--compiler-config",
            json.encode(compiler_config),
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
        resource_set = resource_set_for(mem_mb = ctx.attr.build_memory_mb),
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
    "built_wheel_console_scripts": attr.string_list(
        doc = "Console entry points in the built wheel, encoded as name=module:func. Requires complete built_wheel_top_levels metadata.",
    ),
    "built_wheel_directory_top_levels": attr.string_list(
        doc = "Complete subset of built_wheel_top_levels installed as directories.",
    ),
    "built_wheel_top_levels": attr.string_list(
        doc = "Complete, configuration-invariant list of immediate site-packages entries in the built wheel. Leave empty when the final topology varies by target configuration.",
    ),
    "build_memory_mb": attr.int(
        default = 0,
        doc = "Estimated peak memory in MB for local wheel builds. Bazel rounds " +
              "this up to the next resource class supported by bazel_lib. Zero " +
              "uses Bazel's default estimate.",
    ),
    "src": attr.label(allow_single_file = True),
    "tool": attr.label(executable = True, cfg = "exec"),
    "version": attr.string(),
    "args": attr.string_list(default = ["--validate-anyarch"]),
} | _PATCH_ATTRS

pep517_whl = rule(
    implementation = _pep517_whl,
    doc = """PEP 517 sdist to anyarch whl build rule.

Consumes a sdist artifact and performs a build of that artifact with the
specified Python dependencies under the configured Python toolchain.

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

Toolchains the build action depends on are passed via the standard `toolchains`
attribute and each target's `DefaultInfo.files`, `ToolchainInfo.all_files`, and
`TemplateVariableInfo.variables` are forwarded to the action. The `env`
attribute maps environment variable names to strings that may reference
`$(VAR)` make-variables sourced from those toolchains. This mirrors the
pattern used by `rules_rust`'s `cargo_build_script`.

The build is guaranteed to occur on an execution platform matching the
constraints of the target platform.

""",
    attrs = _pep517_whl_attrs | {
        "args": attr.string_list(),
        "env": attr.string_dict(
            doc = "Environment variables to set on the build action. Values may " +
                  "contain `$(VAR)` references to make-variables exposed by any " +
                  "target in the rule's `toolchains` attribute (via " +
                  "`TemplateVariableInfo`).",
        ),
    },
    fragments = ["cpp"],
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
