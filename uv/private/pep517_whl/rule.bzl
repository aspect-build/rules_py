"""
PEP 517 sdist-to-wheel build rules.

Uses `python -m build` (the pypa/build frontend) which delegates to whatever
build backend the sdist declares in its `[build-system]` table.
"""

load("@bazel_lib//lib:resource_sets.bzl", "resource_set", "resource_set_attr")
load(
    "@rules_cc//cc:action_names.bzl",
    "CPP_COMPILE_ACTION_NAME",
    "CPP_LINK_STATIC_LIBRARY_ACTION_NAME",
    "C_COMPILE_ACTION_NAME",
    "STRIP_ACTION_NAME",
)
load("//py/private/toolchain:types.bzl", "NATIVE_BUILD_TOOLCHAIN", "PY_TOOLCHAIN")

_CC_TOOLCHAIN_TYPE = "@bazel_tools//tools/cpp:toolchain_type"

def _common_env(ctx):
    return {
        "SETUPTOOLS_SCM_PRETEND_VERSION": ctx.attr.version,
        # Determinism: fix hash seed so dict/set iteration order is stable
        "PYTHONHASHSEED": "0",
        # Determinism: reproducible timestamps in archives
        "SOURCE_DATE_EPOCH": "0",
    } | ctx.configuration.default_shell_env

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

def _tool_is_input(tool_path, inputs):
    return any([
        tool_path == f.path or tool_path.startswith(f.path + "/")
        for f in inputs
    ])

def _cc_toolchain_inputs_and_tools(ctx, overrides):
    """Return the target exec group's C++ inputs and native build tools."""
    toolchain = ctx.exec_groups["target"].toolchains[_CC_TOOLCHAIN_TYPE]
    cc_toolchain = toolchain.cc if hasattr(toolchain, "cc_provider_in_toolchain") else toolchain
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )
    cc_files = cc_toolchain.all_files
    cc_inputs = cc_files.to_list()

    # Query action configs rather than CcToolchainInfo's legacy executable
    # fields. rules_cc fabricates paths when tool_paths are omitted:
    # https://github.com/bazelbuild/rules_cc/blob/0.2.16/cc/private/rules_impl/cc_toolchain_provider_helper.bzl#L77-L101
    #
    # These tools run outside Bazel's configured C++ actions, so they must be
    # present in all_files to be available in the wheel-build action.
    # Do not reuse the configured action argv or environment here. Those are
    # parameterized for one Bazel compile action, while PEP 517 backends reuse
    # CC and CXX for their own compile and link commands. Package env remains
    # the explicit interface for additional driver flags.
    compile_tools = {}
    tool_config = {}
    for key, action_name in {
        "CC": C_COMPILE_ACTION_NAME,
        "CXX": CPP_COMPILE_ACTION_NAME,
    }.items():
        if not cc_common.action_is_enabled(
            action_name = action_name,
            feature_configuration = feature_configuration,
        ):
            if not overrides.get(key):
                message = "C++ toolchain does not enable the {} action required for {}".format(action_name, key)
                if key == "CXX":
                    tool_config[key] = {"error": message}
                else:
                    fail(message)
            continue
        tool = cc_common.get_tool_for_action(
            action_name = action_name,
            feature_configuration = feature_configuration,
        )
        compile_tools[key] = tool
        if not _tool_is_input(tool, cc_inputs):
            if not overrides.get(key):
                message = "C++ toolchain {} tool is absent from all_files: {}".format(key, tool)
                if key == "CXX":
                    tool_config[key] = {"error": message}
                else:
                    fail(message)
            continue
        if not overrides.get(key):
            tool_config[key] = [tool]

    for key, action_name in {
        "AR": CPP_LINK_STATIC_LIBRARY_ACTION_NAME,
        "STRIP": STRIP_ACTION_NAME,
    }.items():
        if overrides.get(key):
            continue
        if not cc_common.action_is_enabled(
            action_name = action_name,
            feature_configuration = feature_configuration,
        ):
            continue
        tool = cc_common.get_tool_for_action(
            action_name = action_name,
            feature_configuration = feature_configuration,
        )
        if _tool_is_input(tool, cc_inputs):
            tool_config[key] = [tool]

    # LD has no single C++ action equivalent: executable and shared-library
    # links may select different drivers. Preserve only an explicit override.
    cc = compile_tools.get("CC")
    cxx = compile_tools.get("CXX")
    if not overrides.get("CXX") and cc != None and cc == cxx:
        if cc_toolchain.compiler == "clang":
            # Clang documents this as equivalent to invoking clang++:
            # https://clang.llvm.org/docs/UsersManual.html#cmdoption-driver-mode
            tool_config["CXX"] = [cxx, "--driver-mode=g++"]
        else:
            # Clang is the only shared driver with a documented generic C++
            # mode. GCC requires g++ for C++ mode and libstdc++ linkage, and
            # custom drivers likewise need an explicit CXX command:
            # https://gcc.gnu.org/onlinedocs/gcc/Invoking-G_002b_002b.html
            tool_config["CXX"] = {
                "error": "C++ toolchain '{}' uses '{}' for both CC and CXX; set an explicit CXX override".format(cc_toolchain.compiler, cxx),
            }
    return cc_files, tool_config

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
        resource_set = resource_set(ctx.attr),
    )

    return [DefaultInfo(files = depset([wheel_dir]))]

def _pep517_native_whl(ctx):
    archive = ctx.file.src
    wheel_dir = ctx.actions.declare_directory(ctx.label.name)
    patch_args, patch_inputs = _patch_args_and_inputs(ctx)

    env = _common_env(ctx)
    extra_inputs, known_variables = _collect_toolchain_inputs_and_vars(ctx)

    # Package overrides belong in this rule's env attribute. Do not let an
    # ambient shell compiler replace the configured target toolchain.
    for key in ["AR", "CC", "CPP", "CXX", "LD", "LDCXXSHARED", "LDSHARED", "MPICC", "STRIP"]:
        env.pop(key, None)
    for k, v in ctx.attr.env.items():
        env[k] = ctx.expand_make_variables("env", v, known_variables)

    cc_files, native_tool_config = _cc_toolchain_inputs_and_tools(ctx, env)
    extra_inputs.append(cc_files)

    ctx.actions.run(
        mnemonic = "PySdistNativeBuild",
        progress_message = "Native source compiling {} to a whl".format(archive.basename),
        executable = ctx.executable.tool,
        toolchain = None,
        arguments = ctx.attr.args + patch_args + [
            "--native-tool-config",
            json.encode(native_tool_config),
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

    return [DefaultInfo(files = depset([wheel_dir]))]

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
