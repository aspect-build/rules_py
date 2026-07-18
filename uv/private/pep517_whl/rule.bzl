"""
PEP 517 sdist-to-wheel build rules.

Uses `python -m build` (the pypa/build frontend) which delegates to whatever
build backend the sdist declares in its `[build-system]` table.
"""

load("@bazel_lib//lib:resource_sets.bzl", "resource_set", "resource_set_attr")
load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("//py/private/toolchain:types.bzl", "NATIVE_BUILD_TOOLCHAIN", "PY_TOOLCHAIN")
load("//uv/private:source_built_wheel.bzl", "SourceBuiltWheelInfo")

_CC_TOOLCHAIN_TYPE = Label("@bazel_tools//tools/cpp:toolchain_type")
_TARGET_EXEC_GROUP = "target"
_EXECROOT_MARKER = "__ASPECT_RULES_PY_EXECROOT__"
_CXX_TOOLCHAIN_CONFIG_ENV = "ASPECT_RULES_PY_CXX_TOOLCHAIN_CONFIG"

_INHERITED_PYTHON_ENV = (
    "PYTHONHOME",
    "PYTHONPATH",
    "PYTHONPLATLIBDIR",
)

def _wheel_providers(wheel_dir, console_scripts):
    return [
        DefaultInfo(files = depset([wheel_dir])),
        SourceBuiltWheelInfo(console_scripts = tuple(console_scripts)),
    ]

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
        if key.upper() not in _INHERITED_PYTHON_ENV
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

def _cc_toolchain_inputs_and_tools(ctx):
    """Return the target execution group's C++ files and selected build tools."""
    cc_toolchain = ctx.exec_groups[_TARGET_EXEC_GROUP].toolchains[_CC_TOOLCHAIN_TYPE]
    if hasattr(cc_toolchain, "cc_provider_in_toolchain") and hasattr(cc_toolchain, "cc"):
        cc_toolchain = cc_toolchain.cc
    if not cc_toolchain or not hasattr(cc_toolchain, "all_files"):
        return None, {}
    files = cc_toolchain.all_files

    # Minimal C++ ToolchainInfo implementations can still supply a compiler
    # and its files without a CcToolchainInfo feature configuration.
    if not hasattr(cc_toolchain, "ar_executable"):
        compiler = getattr(cc_toolchain, "compiler_executable", None)
        if not compiler:
            return files, {}
        file_paths = {file.path: True for file in files.to_list()}
        return files, {"CC": compiler, "CXX": _declared_cxx_driver(compiler, file_paths)}

    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )
    action_names = {
        "AR": ACTION_NAMES.cpp_link_static_library,
        "CC": ACTION_NAMES.c_compile,
        "CXX": ACTION_NAMES.cpp_compile,
        "LD": ACTION_NAMES.cpp_link_dynamic_library,
        "STRIP": ACTION_NAMES.strip,
    }

    tools = {
        key: cc_common.get_tool_for_action(
            feature_configuration = feature_configuration,
            action_name = action_name,
        )
        for key, action_name in action_names.items()
        if cc_common.action_is_enabled(
            feature_configuration = feature_configuration,
            action_name = action_name,
        )
    }

    missing = [key for key in action_names if not tools.get(key)]
    if missing:
        # Legacy C++ toolchains can omit action configs while still exposing
        # usable tools through CcToolchainInfo. Action-only providers may
        # fabricate these fields, so require each fallback to be an input.
        file_paths = {file.path: True for file in files.to_list()}
        legacy_tools = {
            "AR": cc_toolchain.ar_executable,
            "CC": cc_toolchain.compiler_executable,
            "CXX": _declared_cxx_driver(cc_toolchain.compiler_executable, file_paths),
            "LD": cc_toolchain.ld_executable,
            "STRIP": cc_toolchain.strip_executable,
        }
        tools.update({key: legacy_tools[key] for key in missing if legacy_tools[key] in file_paths})

    compile_variables = cc_common.create_compile_variables(
        cc_toolchain = cc_toolchain,
        feature_configuration = feature_configuration,
        use_pic = cc_common.is_enabled(feature_configuration = feature_configuration, feature_name = "pic") or
                  cc_common.is_enabled(feature_configuration = feature_configuration, feature_name = "supports_pic"),
    )
    link_variables = cc_common.create_link_variables(
        cc_toolchain = cc_toolchain,
        feature_configuration = feature_configuration,
        is_linking_dynamic_library = True,
    )
    exe_link_variables = cc_common.create_link_variables(
        cc_toolchain = cc_toolchain,
        feature_configuration = feature_configuration,
    )
    flag_actions = {
        "cc_compile_flags": (ACTION_NAMES.c_compile, compile_variables),
        "cxx_compile_flags": (ACTION_NAMES.cpp_compile, compile_variables),
        "cxx_shared_link_flags": (ACTION_NAMES.cpp_link_dynamic_library, link_variables),
        "cxx_exe_link_flags": (ACTION_NAMES.cpp_link_executable, exe_link_variables),
    }
    toolchain_config = {}
    for key, (action_name, variables) in flag_actions.items():
        if cc_common.action_is_enabled(feature_configuration = feature_configuration, action_name = action_name):
            flags = cc_common.get_memory_inefficient_command_line(
                feature_configuration = feature_configuration,
                action_name = action_name,
                variables = variables,
            )
            normalized_flags = []
            for index, flag in enumerate(flags):
                for prefix in ["--sysroot=", "--gcc-toolchain=", "-resource-dir=", "-fsanitize-ignorelist=", "-isystem", "-iquote", "-I", "-L", "-B", ""]:
                    if not flag.startswith(prefix):
                        continue
                    value = flag[len(prefix):]
                    is_path_operand = index and flags[index - 1] in ["--sysroot", "-isysroot", "--gcc-toolchain", "-resource-dir", "-isystem", "-iquote", "-I", "-L", "-B"]
                    is_clang_path_operand = index >= 2 and flags[index - 1] == "-Xclang" and flags[index - 2] in ["-internal-isystem", "-internal-externc-isystem"]
                    is_path_flag = prefix and not (prefix == "-B" and value in ["dynamic", "static"])
                    is_execroot_path = value.startswith("external/") or value.startswith("bazel-out/") or value.startswith("../")
                    if value and not value.startswith("/") and (is_path_flag or is_path_operand or is_clang_path_operand or is_execroot_path):
                        flag = prefix + _EXECROOT_MARKER + "/" + value
                        break
                normalized_flags.append(flag)
            toolchain_config[key] = normalized_flags

    if "CC" in ctx.attr.env:
        toolchain_config.pop("cc_compile_flags", None)
    if "CXX" in ctx.attr.env:
        for key in ["cxx_compile_flags", "cxx_shared_link_flags", "cxx_exe_link_flags"]:
            toolchain_config.pop(key, None)
    else:
        for key, action_name in {
            "cxx_shared_link_tool": ACTION_NAMES.cpp_link_dynamic_library,
            "cxx_exe_link_tool": ACTION_NAMES.cpp_link_executable,
        }.items():
            if cc_common.action_is_enabled(feature_configuration = feature_configuration, action_name = action_name):
                tool = cc_common.get_tool_for_action(
                    feature_configuration = feature_configuration,
                    action_name = action_name,
                )
                if tool:
                    toolchain_config[key] = tool
    if toolchain_config:
        tools[_CXX_TOOLCHAIN_CONFIG_ENV] = json.encode(toolchain_config)

    return files, {key: value for key, value in tools.items() if value}

def _declared_cxx_driver(compiler, file_paths):
    basename = compiler.split("/")[-1]
    for cc_basename, cxx_basename in [("clang", "clang++"), ("gcc", "g++")]:
        if basename == cc_basename:
            suffix = ""
        elif basename.startswith(cc_basename + "-") and basename[len(cc_basename) + 1:].isdigit():
            suffix = basename[len(cc_basename):]
        else:
            continue
        dirname_index = compiler.rfind("/")
        companion = cxx_basename + suffix
        if dirname_index != -1:
            companion = compiler[:dirname_index] + "/" + companion
        return companion if companion in file_paths else compiler
    return compiler

def _pep517_whl(ctx):
    archive = ctx.file.src
    wheel_dir = ctx.actions.declare_directory("whl")
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
        arguments = ctx.attr.args + patch_args + _memory_args(ctx) + [
            archive.path,
            wheel_dir.path,
        ],
        inputs = [archive] + patch_inputs,
        tools = [ctx.attr.tool[DefaultInfo].files_to_run],
        outputs = [wheel_dir],
        env = _common_env(ctx),
        exec_group = _TARGET_EXEC_GROUP,
        resource_set = resource_set(ctx.attr),
    )

    return _wheel_providers(wheel_dir, ctx.attr.console_scripts)

def _pep517_native_whl(ctx):
    archive = ctx.file.src
    wheel_dir = ctx.actions.declare_directory("whl")
    patch_args, patch_inputs = _patch_args_and_inputs(ctx)

    env = _common_env(ctx)
    extra_inputs, known_variables = _collect_toolchain_inputs_and_vars(ctx)

    if "EXECROOT" in known_variables:
        fail("A toolchain listed in `toolchains` exports the reserved `EXECROOT` make-variable.")
    known_variables["EXECROOT"] = _EXECROOT_MARKER

    cc_files, cc_tools = _cc_toolchain_inputs_and_tools(ctx)
    if cc_files:
        extra_inputs.append(cc_files)

    for k, v in ctx.attr.env.items():
        env[k] = ctx.expand_make_variables("env", v, known_variables)

    for key, value in cc_tools.items():
        if key not in ctx.attr.env:
            env[key] = value

    ctx.actions.run(
        mnemonic = "PySdistNativeBuild",
        progress_message = "Native source compiling {} to a whl".format(archive.basename),
        executable = ctx.executable.tool,
        toolchain = None,
        arguments = ctx.attr.args + patch_args + _memory_args(ctx) + [
            "--execroot-marker",
            _EXECROOT_MARKER,
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
        exec_group = _TARGET_EXEC_GROUP,
        resource_set = resource_set(ctx.attr),
    )

    return _wheel_providers(wheel_dir, ctx.attr.console_scripts)

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
    # The wheel action uses the named group below, so its frontend must use the
    # same execution platform:
    # https://bazel.build/extending/exec-groups#defining-exec-groups
    "tool": attr.label(executable = True, cfg = config.exec(_TARGET_EXEC_GROUP)),
    "version": attr.string(),
    "console_scripts": attr.string_list(
        doc = "Console scripts discovered from the source distribution's entry-point metadata.",
    ),
    "args": attr.string_list(default = ["--validate-anyarch"]),
    "monitor_memory": attr.bool(
        default = False,
        doc = "Report approximate Linux process-tree RSS while building the wheel.",
    ),
} | _PATCH_ATTRS | resource_set_attr

pep517_whl = rule(
    implementation = _pep517_whl,
    doc = """PEP 517 sdist to anyarch whl build rule.

Consumes a sdist artifact and performs a build of that artifact with the
specified Python dependencies under the configured Python toolchain.

""",
    attrs = _pep517_whl_attrs,
    exec_groups = {
        _TARGET_EXEC_GROUP: exec_group(
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

Extra toolchains the build action depends on are passed via the standard `toolchains`
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
                  "`TemplateVariableInfo`). Prefix an execroot-relative path with " +
                  "`$(EXECROOT)/` so it remains valid after the backend changes into " +
                  "the unpacked source tree. Omit CC/CXX/AR/LD/STRIP to use the " +
                  "configured C++ action tools.",
        ),
    },
    fragments = ["cpp"],
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
        _TARGET_EXEC_GROUP: exec_group(
            toolchains = [
                PY_TOOLCHAIN,
                NATIVE_BUILD_TOOLCHAIN,
                _CC_TOOLCHAIN_TYPE,
            ],
        ),
    },
)
