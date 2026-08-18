"""PEP 517 sdist to platform-specific whl build rule."""

load("@bazel_lib//lib:resource_sets.bzl", "resource_set")
load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("//py/private/interpreter:versions.bzl", "PLATFORMS")
load("//py/private/toolchain:types.bzl", "EXEC_TOOLS_TOOLCHAIN", "NATIVE_BUILD_TOOLCHAIN", "PY_TOOLCHAIN")
load(":cc_layer.bzl", "CC_LAYER_ATTRS", "extract_cc_layer")
load(
    ":common.bzl",
    "PEP517_WHL_ATTRS",
    "TARGET_EXEC_GROUP",
    "common_env",
    "memory_args",
    "patch_args_and_inputs",
    "tool_files_to_run",
    "wheel_providers",
)
load(":exec_transition.bzl", "exec_transition")

_CC_TOOLCHAIN_TYPE = Label("@bazel_tools//tools/cpp:toolchain_type")
_EXECROOT_MARKER = "__ASPECT_RULES_PY_EXECROOT__"
_INFER_CXX_COMPANION = "ASPECT_RULES_PY_INFER_CXX_COMPANION"

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
    cc_toolchain = ctx.exec_groups[TARGET_EXEC_GROUP].toolchains[_CC_TOOLCHAIN_TYPE]
    if hasattr(cc_toolchain, "cc_provider_in_toolchain") and hasattr(cc_toolchain, "cc"):
        cc_toolchain = cc_toolchain.cc
    if not cc_toolchain or not hasattr(cc_toolchain, "all_files"):
        return None, {}, False
    files = cc_toolchain.all_files

    # Minimal C++ ToolchainInfo implementations can still supply a compiler
    # and its files without a CcToolchainInfo feature configuration.
    if not hasattr(cc_toolchain, "ar_executable"):
        compiler = getattr(cc_toolchain, "compiler_executable", None)
        if not compiler:
            return files, {}, False
        return files, {"CC": compiler, "CXX": compiler}, True

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
    infer_cxx = "CXX" in missing
    if missing:
        # Legacy toolchains may omit action configs, while action-only providers may
        # fabricate legacy executable fields; fallbacks must therefore appear in
        # all_files. tool_paths shims may still lack driver-relative sibling tools.
        file_paths = {file.path: True for file in files.to_list()}
        legacy_tools = {
            "AR": cc_toolchain.ar_executable,
            "CC": cc_toolchain.compiler_executable,
            "CXX": cc_toolchain.compiler_executable,
            "LD": cc_toolchain.ld_executable,
            "STRIP": cc_toolchain.strip_executable,
        }
        tools.update({key: legacy_tools[key] for key in missing if legacy_tools[key] in file_paths})

    infer_cxx = infer_cxx or tools.get("CXX") == tools.get("CC")
    return files, {key: value for key, value in tools.items() if value}, infer_cxx

_PYTHON_CPU_MAP = {
    "x86_64": "x86_64",
    "aarch64": "aarch64",
    "x86": "i686",
    # armv7 CPython reports "linux-armv7l"; build_helper's tag validation
    # expects the same spelling.
    "arm": "armv7l",
}

def _find_sysconfigdata(runtime):
    """Locate _sysconfigdata*.py inside the target interpreter's file tree."""
    if not runtime or not hasattr(runtime, "interpreter_version_info"):
        return None
    info = runtime.interpreter_version_info
    prefix = "lib/python{}.{}".format(info.major, info.minor)
    for f in runtime.files.to_list():
        if f.basename.startswith("_sysconfigdata") and f.basename.endswith(".py") and prefix in f.path:
            return f
    return None

def _derive_python_host_platform(target_os, target_cpu):
    """Derive _PYTHON_HOST_PLATFORM from target platform constraints.

    Linux: libc does not affect the platform string — always linux-{cpu}.
    macOS: uses arm64 (not aarch64) and requires a version component. The
    version here is only an analysis-time fallback: the deployment target is
    a property of the target interpreter, which analysis can't read, so
    build_helper re-derives it at build time from the target sysconfigdata's
    MACOSX_DEPLOYMENT_TARGET whenever that file is available.
    """
    if target_os == "linux":
        return "linux-" + _PYTHON_CPU_MAP.get(target_cpu, target_cpu)
    if target_os == "darwin":
        cpu = "arm64" if target_cpu == "aarch64" else target_cpu
        return "macosx-11.0-" + cpu
    return None

def _interpreter_platform_triple(runtime):
    """Best-effort platform triple of the repo a PyRuntimeInfo comes from.

    Interpreter repositories encode the PBS platform triple in their name
    (`python_3_12_aarch64-apple-darwin`, sanitized variants with underscores,
    and rules_python's hyphenated `python_3_11_aarch64-apple-darwin`).
    Returns the matching PLATFORMS key, or None when the interpreter's origin
    is not recognizable (custom or non-hermetic toolchains).
    """
    if runtime == None or runtime.interpreter == None:
        return None
    short_path = runtime.interpreter.short_path
    repo = short_path.split("/")[1] if short_path.startswith("../") else short_path.split("/")[0]
    for triple in PLATFORMS:
        if triple in repo or triple.replace("-", "_") in repo:
            return triple
    return None

def _cross_compile(ctx, eg_toolchains):
    """Decide cross mode from exec/target interpreter platform identities.

    The exec interpreter (EXEC_TOOLS_TOOLCHAIN, selected by exec platform)
    and the target interpreter (PY_TOOLCHAIN, selected by target platform)
    carry their origin repo's platform triple. Identical triples prove
    exec == target, so a native build stays native even when the optional
    NATIVE_BUILD_TOOLCHAIN sentinel is not registered for the platform.

    When either identity is unrecognizable (custom interpreters), fall back
    to the sentinel's absence as the cross signal — the previous behavior.
    """
    exec_tc = eg_toolchains[EXEC_TOOLS_TOOLCHAIN]
    py_tc = ctx.toolchains[PY_TOOLCHAIN]
    exec_triple = _interpreter_platform_triple(getattr(exec_tc, "exec_runtime", None) if exec_tc != None else None)
    target_triple = _interpreter_platform_triple(getattr(py_tc, "py3_runtime", None) if py_tc != None else None)
    if exec_triple and target_triple:
        return exec_triple != target_triple
    return eg_toolchains[NATIVE_BUILD_TOOLCHAIN] == None

def _pep517_native_whl(ctx):
    archive = ctx.file.src

    # Fixed name; the backend picks the real filename at build time and the
    # helper renames onto this. Consumers read identity from dist-info only.
    wheel_file = ctx.actions.declare_file(ctx.label.name + ".whl")
    patch_args, patch_inputs = patch_args_and_inputs(ctx)

    eg_toolchains = ctx.exec_groups[TARGET_EXEC_GROUP].toolchains
    cross = _cross_compile(ctx, eg_toolchains)
    cc_toolchain_raw = eg_toolchains[_CC_TOOLCHAIN_TYPE]

    if cc_toolchain_raw == None:
        if cross:
            fail(
                ("Cross-compilation of sdist '{}' requires a CC toolchain " +
                 "registered for the target platform. No toolchain of type {} " +
                 "resolved against the current exec/target platform combination.\n" +
                 "Register a cross CC toolchain (e.g., toolchains_llvm with " +
                 "matching target_compatible_with) via register_toolchains.").format(
                    ctx.attr.src.label,
                    _CC_TOOLCHAIN_TYPE,
                ),
            )
        fail(
            ("sdist '{}' requires a CC toolchain but none resolved. " +
             "Register a CC toolchain (e.g., rules_cc, toolchains_llvm) " +
             "via register_toolchains.").format(ctx.attr.src.label),
        )

    cc_toolchain = cc_toolchain_raw
    if hasattr(cc_toolchain, "cc_provider_in_toolchain") and hasattr(cc_toolchain, "cc"):
        cc_toolchain = cc_toolchain.cc

    env = common_env(ctx)
    extra_inputs, known_variables = _collect_toolchain_inputs_and_vars(ctx)

    if "EXECROOT" in known_variables:
        fail("A toolchain listed in `toolchains` exports the reserved `EXECROOT` make-variable.")
    known_variables["EXECROOT"] = _EXECROOT_MARKER

    cc_files, cc_tools, infer_cxx = _cc_toolchain_inputs_and_tools(ctx)
    if cc_files:
        extra_inputs.append(cc_files)
    known_variables.update({key: value for key, value in cc_tools.items() if key not in known_variables})

    for k, v in ctx.attr.env.items():
        env[k] = ctx.expand_make_variables("env", v, known_variables)

    for key, value in cc_tools.items():
        if key not in ctx.attr.env:
            env[key] = value

    env.pop(_INFER_CXX_COMPANION, None)
    if "CXX" not in ctx.attr.env and cc_tools.get("CXX") and infer_cxx:
        env[_INFER_CXX_COMPANION] = "1"

    if cross:
        cc_layer = extract_cc_layer(ctx, cc_toolchain)
        env["RULES_PY_CROSS_COMPILE"] = "1"
        env["RULES_PY_TARGET_OS"] = cc_layer.target_os or ""
        env["RULES_PY_TARGET_CPU"] = cc_layer.target_cpu or ""
        if cc_layer.static_runtime_files:
            extra_inputs.append(cc_layer.static_runtime_files)
        if cc_layer.static_runtime_paths:
            env["RULES_PY_CXX_STATIC_RUNTIME"] = ":".join(cc_layer.static_runtime_paths)
        if cc_layer.cflags:
            env["CFLAGS"] = cc_layer.cflags
        if cc_layer.cxxflags:
            env["CXXFLAGS"] = cc_layer.cxxflags
        if cc_layer.ldflags:
            env["LDFLAGS"] = cc_layer.ldflags
        if cc_layer.ldshared_flags:
            env["LDSHAREDFLAGS"] = cc_layer.ldshared_flags
        if cc_layer.ccshared:
            env["CFLAGS"] = (env.get("CFLAGS", "") + " " + cc_layer.ccshared).strip()
            env["CXXFLAGS"] = (env.get("CXXFLAGS", "") + " " + cc_layer.ccshared).strip()
        cross_args = [
            "--cross",
            "--target-os",
            cc_layer.target_os or "",
            "--target-cpu",
            cc_layer.target_cpu or "",
        ]

        py_toolchain = ctx.toolchains[PY_TOOLCHAIN]
        if py_toolchain != None:
            runtime = getattr(py_toolchain, "py3_runtime", None)
            if runtime:
                sysconfig_file = _find_sysconfigdata(runtime)
                if sysconfig_file:
                    extra_inputs.append(depset([sysconfig_file]))
                    env["RULES_PY_TARGET_SYSCONFIGDATA"] = sysconfig_file.path

        host_platform = _derive_python_host_platform(cc_layer.target_os, cc_layer.target_cpu)
        if host_platform:
            env["_PYTHON_HOST_PLATFORM"] = host_platform
    else:
        cross_args = []

    tool = tool_files_to_run(ctx)

    ctx.actions.run(
        mnemonic = "PySdistCrossBuild" if cross else "PySdistNativeBuild",
        progress_message = "{} source compiling {} to a whl".format(
            "Cross" if cross else "Native",
            archive.basename,
        ),
        executable = tool,
        toolchain = None,
        arguments = ctx.attr.args + patch_args + memory_args(ctx) + cross_args + [
            "--execroot-marker",
            _EXECROOT_MARKER,
            archive.path,
            wheel_file.path,
        ],
        inputs = depset(
            [archive] + patch_inputs,
            transitive = extra_inputs,
        ),
        tools = [tool],
        outputs = [wheel_file],
        env = env,
        exec_group = TARGET_EXEC_GROUP,
        resource_set = resource_set(ctx.attr),
    )

    return wheel_providers(wheel_file, ctx.attr.console_scripts)

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

In native mode (exec platform == target platform) the build uses the host
CC toolchain. Cross mode is decided by comparing the platform triples of the
exec interpreter (exec-tools toolchain) and the target interpreter (Python
toolchain): differing triples enter cross mode, where the CC toolchain of
the "target" exec group resolves against a user-registered cross CC toolchain
(e.g., toolchains_llvm). If no cross CC toolchain is found, analysis fails
with a diagnostic naming the required toolchain type. When the interpreter
origins are unrecognizable, the optional NATIVE_BUILD_TOOLCHAIN sentinel's
absence is used as the cross signal.

""",
    attrs = PEP517_WHL_ATTRS | {
        "args": attr.string_list(),
        "env": attr.string_dict(
            doc = "Environment variables to set on the build action. Values may " +
                  "contain `$(VAR)` references to the configured C++ action tools " +
                  "or make-variables exposed by any target in the rule's " +
                  "`toolchains` attribute (via `TemplateVariableInfo`). Prefix an " +
                  "execroot-relative path with " +
                  "`$(EXECROOT)/` so it remains valid after the backend changes into " +
                  "the unpacked source tree. Omit CC/CXX/AR/LD/STRIP to use the " +
                  "configured C++ action tools.",
        ),
        "tool": attr.label(executable = True, cfg = exec_transition),
    } | CC_LAYER_ATTRS,
    fragments = ["cpp"],
    toolchains = [
        config_common.toolchain_type(PY_TOOLCHAIN, mandatory = False),
    ],
    exec_groups = {
        TARGET_EXEC_GROUP: exec_group(
            toolchains = [
                PY_TOOLCHAIN,
                config_common.toolchain_type(EXEC_TOOLS_TOOLCHAIN, mandatory = False),
                config_common.toolchain_type(NATIVE_BUILD_TOOLCHAIN, mandatory = False),
                config_common.toolchain_type(_CC_TOOLCHAIN_TYPE, mandatory = False),
            ],
        ),
    },
)
