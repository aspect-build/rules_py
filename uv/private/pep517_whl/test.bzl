"""Analysis tests for the pep517_native_whl toolchain boundary.

Inspecting the action at analysis time avoids actually running a PEP 517
build to verify the command and environment wiring.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load(
    "@rules_cc//cc:action_names.bzl",
    "CPP_COMPILE_ACTION_NAME",
    "CPP_LINK_EXECUTABLE_ACTION_NAME",
    "CPP_LINK_STATIC_LIBRARY_ACTION_NAME",
    "C_COMPILE_ACTION_NAME",
    "STRIP_ACTION_NAME",
)
load(
    "@rules_cc//cc:cc_toolchain_config_lib.bzl",
    "action_config",
    "env_entry",
    "env_set",
    "feature",
    "flag_group",
    "flag_set",
    "tool",
)
load("@rules_cc//cc:defs.bzl", "cc_toolchain")

# Env vars sourced from the Java runtime toolchain's TemplateVariableInfo.
_JDK_ENV_KEYS = ["JAVA_HOME", "JAVA", "JAR"]

_NATIVE_TOOL_ENV_KEYS = ["AR", "CC", "CXX", "LD", "STRIP"]
_REQUIRED_NATIVE_TOOL_KEYS = ["CC", "CXX"]
_UNSET_DEFAULT_ENV_KEYS = _NATIVE_TOOL_ENV_KEYS + [
    "CPP",
    "LDCXXSHARED",
    "LDSHARED",
    "MPICC",
]

def _compiler_selection_toolchain_config_impl(ctx):
    action_tools = {
        CPP_LINK_EXECUTABLE_ACTION_NAME: ctx.executable.ld_driver.basename,
    }
    if "CC" in ctx.attr.compiler_actions:
        action_tools[C_COMPILE_ACTION_NAME] = ctx.executable.c_driver.basename
    if "CXX" in ctx.attr.compiler_actions:
        action_tools[CPP_COMPILE_ACTION_NAME] = ctx.executable.cxx_driver.basename
    if "AR" in ctx.attr.optional_tools:
        action_tools[CPP_LINK_STATIC_LIBRARY_ACTION_NAME] = ctx.executable.ar_driver.basename
    if "STRIP" in ctx.attr.optional_tools:
        action_tools[STRIP_ACTION_NAME] = ctx.executable.strip_driver.basename
    features = [feature(
        name = "sentinel_action_environment",
        enabled = True,
        env_sets = [env_set(
            actions = [C_COMPILE_ACTION_NAME, CPP_COMPILE_ACTION_NAME],
            env_entries = [env_entry(key = "SENTINEL_ACTION_ENV", value = "configured")],
        )],
    )]
    if ctx.attr.no_legacy_features:
        # rules_cc synthesizes action configs for omitted actions unless this
        # compatibility feature is present:
        # https://github.com/bazelbuild/rules_cc/blob/0.2.16/cc/private/toolchain_config/cc_toolchain_config_info.bzl#L76-L121
        features.append(feature(name = "no_legacy_features", enabled = True))
    return cc_common.create_cc_toolchain_config_info(
        ctx = ctx,
        abi_libc_version = "unknown",
        abi_version = "unknown",
        action_configs = [
            action_config(
                action_name = action_name,
                enabled = True,
                flag_sets = [flag_set(
                    flag_groups = [flag_group(flags = ["--sentinel-action-flag=" + action_name])],
                )],
                tools = [tool(path = action_tools[action_name])],
            )
            for action_name in action_tools
        ],
        compiler = ctx.attr.compiler,
        features = features,
        host_system_name = "local",
        target_cpu = "test",
        target_libc = "unknown",
        target_system_name = "local",
        # Deliberately action-only: rules_cc fabricates legacy executable
        # fields for omitted tool_paths, so tests must exercise action configs.
        tool_paths = [],
        toolchain_identifier = ctx.label.name,
    )

compiler_selection_toolchain_config = rule(
    implementation = _compiler_selection_toolchain_config_impl,
    attrs = {
        "ar_driver": attr.label(
            cfg = "exec",
            allow_files = True,
            executable = True,
            mandatory = True,
        ),
        "c_driver": attr.label(
            cfg = "exec",
            allow_files = True,
            executable = True,
            mandatory = True,
        ),
        "cxx_driver": attr.label(
            cfg = "exec",
            allow_files = True,
            executable = True,
            mandatory = True,
        ),
        "compiler": attr.string(mandatory = True),
        "compiler_actions": attr.string_list(mandatory = True),
        "ld_driver": attr.label(
            cfg = "exec",
            allow_files = True,
            executable = True,
            mandatory = True,
        ),
        "no_legacy_features": attr.bool(mandatory = True),
        "optional_tools": attr.string_list(mandatory = True),
        "strip_driver": attr.label(
            cfg = "exec",
            allow_files = True,
            executable = True,
            mandatory = True,
        ),
    },
    provides = [CcToolchainConfigInfo],
)

def compiler_selection_toolchain(name, ar_driver, c_driver, cxx_driver, compiler, compiler_actions, ld_driver, no_legacy_features, optional_tools, strip_driver):
    """Declare a synthetic C++ toolchain for compiler-selection tests."""
    files = name + "_files"
    config = name + "_config"
    native.filegroup(
        name = files,
        srcs = depset([ar_driver, c_driver, cxx_driver, ld_driver, strip_driver]).to_list(),
        tags = ["manual"],
    )
    compiler_selection_toolchain_config(
        name = config,
        ar_driver = ar_driver,
        c_driver = c_driver,
        compiler = compiler,
        compiler_actions = compiler_actions,
        cxx_driver = cxx_driver,
        ld_driver = ld_driver,
        no_legacy_features = no_legacy_features,
        optional_tools = optional_tools,
        strip_driver = strip_driver,
        tags = ["manual"],
    )
    cc_toolchain(
        name = name,
        all_files = files,
        ar_files = files,
        as_files = files,
        compiler_files = files,
        dwp_files = files,
        linker_files = files,
        objcopy_files = files,
        strip_files = files,
        supports_param_files = 0,
        tags = ["manual"],
        toolchain_config = config,
    )
    native.toolchain(
        name = name + "_toolchain",
        tags = ["manual"],
        toolchain = name,
        toolchain_type = "@bazel_tools//tools/cpp:toolchain_type",
    )

def _toolchain_env_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)

    build_actions = [a for a in target.actions if a.mnemonic == "PySdistNativeBuild"]
    asserts.equals(
        env,
        1,
        len(build_actions),
        "expected exactly one PySdistNativeBuild action",
    )

    action = build_actions[0]
    action_env = action.env
    asserts.false(
        env,
        "SENTINEL_ACTION_ENV" in action_env,
        "configured compile environment must not enter the wheel-build action",
    )
    if ctx.attr.check_toolchain_env:
        missing = [k for k in _JDK_ENV_KEYS if k not in action_env]
        asserts.equals(
            env,
            [],
            missing,
            "missing env keys on action; got: {}".format(sorted(action_env.keys())),
        )
        for key in _JDK_ENV_KEYS:
            asserts.true(
                env,
                action_env.get(key),
                "${} should resolve to a non-empty value".format(key),
            )
        for key in _UNSET_DEFAULT_ENV_KEYS:
            asserts.false(
                env,
                key in action_env,
                "{} should not be baked into the action environment".format(key),
            )

    config_arg_indexes = [
        i
        for i in range(len(action.argv))
        if action.argv[i] == "--native-tool-config"
    ]
    asserts.equals(env, 1, len(config_arg_indexes))
    native_tool_config_json = action.argv[config_arg_indexes[0] + 1]
    native_tool_config = json.decode(native_tool_config_json)
    missing_tools = [
        key
        for key in _REQUIRED_NATIVE_TOOL_KEYS
        if key not in ctx.attr.expected_env and key not in native_tool_config
    ]
    asserts.equals(env, [], missing_tools)
    inputs = action.inputs.to_list()
    expected_config = {
        key: [compiler] + (ctx.attr.expected_cxx_args if key == "CXX" else [])
        for key, compiler in ctx.attr.expected_tools.items()
    }
    expected_config.update({
        key: {"error": error}
        for key, error in ctx.attr.expected_tool_errors.items()
    })
    if expected_config:
        asserts.equals(env, sorted(expected_config), sorted(native_tool_config))
        asserts.equals(env, expected_config, native_tool_config)

    # Bazel's action flags and environment describe one compile invocation,
    # but PEP 517 backends reuse CC and CXX for compile and link commands.
    asserts.false(env, "sentinel-action-flag" in native_tool_config_json)
    asserts.false(env, "SENTINEL_ACTION_ENV" in native_tool_config_json)
    for command in native_tool_config.values():
        if type(command) != "list":
            continue

        # Per https://bazel.build/rules/lib/builtins/File#is_directory:
        #
        # File.is_directory reflects the type the file was declared as, not
        # its type on the filesystem. Toolchain inputs may contain a source
        # directory instead of each tool, so test path ancestry.
        asserts.true(
            env,
            any([
                command[0] == f.path or
                command[0].startswith(f.path + "/")
                for f in inputs
            ]),
            "configured tool must be covered by an action input: {}".format(command[0]),
        )

    for key, expected in ctx.attr.expected_env.items():
        asserts.equals(
            env,
            expected,
            action_env.get(key),
            "explicit {} should replace the toolchain default".format(key),
        )

    if ctx.attr.check_toolchain_env:
        # JAR is constructed from $(JAVABASE)/bin/jar — sanity-check the suffix.
        asserts.true(
            env,
            action_env.get("JAR", "").endswith("/bin/jar"),
            "JAR should resolve under JAVA_HOME/bin/jar; got {}".format(action_env.get("JAR")),
        )

    return analysistest.end(env)

def _toolchain_env_test_attrs():
    return {
        "check_toolchain_env": attr.bool(),
        "expected_cxx_args": attr.string_list(),
        "expected_env": attr.string_dict(),
        "expected_tool_errors": attr.string_dict(),
        "expected_tools": attr.string_dict(),
    }

pep517_native_whl_toolchain_env_test = analysistest.make(
    _toolchain_env_test_impl,
    attrs = _toolchain_env_test_attrs(),
)

pep517_native_whl_compiler_selection_test = analysistest.make(
    _toolchain_env_test_impl,
    attrs = _toolchain_env_test_attrs(),
    config_settings = {
        "//command_line_option:extra_toolchains": [
            "//uv/private/pep517_whl:__compiler_selection_toolchain",
        ],
    },
)

pep517_native_whl_same_driver_clang_test = analysistest.make(
    _toolchain_env_test_impl,
    attrs = _toolchain_env_test_attrs(),
    config_settings = {
        "//command_line_option:extra_toolchains": [
            "//uv/private/pep517_whl:__same_driver_clang_toolchain",
        ],
    },
)

pep517_native_whl_same_driver_gcc_test = analysistest.make(
    _toolchain_env_test_impl,
    attrs = _toolchain_env_test_attrs(),
    config_settings = {
        "//command_line_option:extra_toolchains": [
            "//uv/private/pep517_whl:__same_driver_gcc_toolchain",
        ],
    },
)

pep517_native_whl_missing_cxx_test = analysistest.make(
    _toolchain_env_test_impl,
    attrs = _toolchain_env_test_attrs(),
    config_settings = {
        "//command_line_option:extra_toolchains": [
            "//uv/private/pep517_whl:__missing_cxx_toolchain",
        ],
    },
)

pep517_native_whl_disabled_cxx_test = analysistest.make(
    _toolchain_env_test_impl,
    attrs = _toolchain_env_test_attrs(),
    config_settings = {
        "//command_line_option:extra_toolchains": [
            "//uv/private/pep517_whl:__disabled_cxx_toolchain",
        ],
    },
)
