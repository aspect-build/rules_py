"""PEP 517 sdist to platform-specific whl build rule.

Uses `python -m build` (the pypa/build frontend) which delegates to whatever
build backend the sdist declares in its `[build-system]` table.
"""

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
    "wheel_providers",
)

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

# Deployment-target floor for the macOS platform string when the real value
# is unknown: 11.0 is the first macOS release with arm64 support, so it is
# the most conservative version every hermetic arm64 interpreter satisfies.
# build_helper re-derives the real value from the target sysconfigdata's
# MACOSX_DEPLOYMENT_TARGET whenever that file is available.
_MACOS_DEPLOYMENT_FALLBACK = "11.0"

def _target_python_artifacts(runtime):
    """Collect the target interpreter files a cross build must see.

    One pass over the runtime's file tree: the _sysconfigdata*.py module
    (faked into the backend via _PYTHON_SYSCONFIGDATA_NAME) and the
    include/pythonX.Y header tree — the compile must use the target's
    Python.h/pyconfig.h, not the exec runtime's, or the wheel is built
    against the wrong ABI.
    """
    if not runtime or not hasattr(runtime, "interpreter_version_info"):
        return struct(sysconfig = None, include_files = [], include_dir = None)
    info = runtime.interpreter_version_info
    lib_prefix = "lib/python{}.{}".format(info.major, info.minor)
    include_marker = "/include/python{}.{}".format(info.major, info.minor)
    sysconfig_file = None
    include_files = []
    include_dir = None
    for f in runtime.files.to_list():
        if f.basename.startswith("_sysconfigdata") and f.basename.endswith(".py") and lib_prefix in f.path:
            sysconfig_file = f
        elif include_marker in f.path:
            include_files.append(f)
            if f.basename == "pyconfig.h":
                include_dir = f.dirname
    return struct(
        sysconfig = sysconfig_file,
        include_files = include_files,
        include_dir = include_dir,
    )

def _derive_python_host_platform(target_os, target_cpu):
    """Derive _PYTHON_HOST_PLATFORM from target platform constraints.

    Linux: libc does not affect the platform string — always linux-{cpu}.
    macOS: uses arm64 (not aarch64) and requires a version component,
    defaulting to _MACOS_DEPLOYMENT_FALLBACK when the interpreter's real
    deployment target is not known.
    """
    if target_os == "linux":
        return "linux-" + _PYTHON_CPU_MAP.get(target_cpu, target_cpu)
    if target_os == "darwin":
        cpu = "arm64" if target_cpu == "aarch64" else target_cpu
        return "macosx-{}-{}".format(_MACOS_DEPLOYMENT_FALLBACK, cpu)
    return None

def _interpreter_platform_triple(runtime):
    """Best-effort platform triple of the repo a PyRuntimeInfo comes from.

    Interpreter repositories encode the PBS platform triple in their name
    (`python_3_12_aarch64-apple-darwin`, sanitized variants with underscores,
    and rules_python's hyphenated `python_3_11_aarch64-apple-darwin`).
    Returns the matching PLATFORMS key, or None when the interpreter's origin
    is not recognizable (custom or non-hermetic toolchains).
    """
    if runtime == None or getattr(runtime, "interpreter", None) == None:
        return None
    short_path = runtime.interpreter.short_path
    repo = short_path.split("/")[1] if short_path.startswith("../") else short_path.split("/")[0]
    for triple in PLATFORMS:
        if triple in repo or triple.replace("-", "_") in repo:
            return triple
    return None

def _cross_decision(exec_triple, target_triple, has_native_build_toolchain):
    """Whether building on this execution platform would cross-compile.

    Identical exec and target interpreter triples prove exec == target, so a
    native build stays native even when the NATIVE_BUILD_TOOLCHAIN sentinel is
    not registered for the platform. When either identity is unrecognizable
    (custom interpreters), fall back to the sentinel's absence as the cross
    signal — the sentinel only resolves when exec and target platforms match.
    """
    if exec_triple and target_triple:
        return exec_triple != target_triple
    return not has_native_build_toolchain

def _cross_compile(ctx, eg_toolchains):
    """Cross decision plus the interpreter triples it was based on."""
    exec_tc = eg_toolchains[EXEC_TOOLS_TOOLCHAIN]
    py_tc = ctx.toolchains[PY_TOOLCHAIN]
    exec_triple = _interpreter_platform_triple(getattr(exec_tc, "exec_runtime", None) if exec_tc != None else None)
    target_triple = _interpreter_platform_triple(getattr(py_tc, "py3_runtime", None) if py_tc != None else None)
    cross = _cross_decision(exec_triple, target_triple, eg_toolchains[NATIVE_BUILD_TOOLCHAIN] != None)
    return cross, exec_triple, target_triple

# Exposed for the unit tests in tests/pep517_whl_test.bzl only.
cross_detection_test_util = struct(
    interpreter_platform_triple = _interpreter_platform_triple,
    cross_decision = _cross_decision,
)

# Exposed for the unit tests in tests/pep517_whl_test.bzl only.
cross_identity_test_util = struct(
    derive_python_host_platform = _derive_python_host_platform,
    target_python_artifacts = _target_python_artifacts,
)

def _pep517_native_whl(ctx):
    archive = ctx.file.src

    eg_toolchains = ctx.exec_groups[TARGET_EXEC_GROUP].toolchains
    cross, _exec_triple, _target_triple = _cross_compile(ctx, eg_toolchains)

    # A missing C++ toolchain must stay an explicit analysis error (it used
    # to be a resolution failure when the type was mandatory) — otherwise the
    # backend compiles with whatever ambient compiler the sandbox exposes,
    # or fails at execution time.
    cc_toolchain_raw = eg_toolchains[_CC_TOOLCHAIN_TYPE]
    if cc_toolchain_raw == None:
        if cross:
            fail(
                "{}: cross-compiling this sdist requires a C++ toolchain that ".format(ctx.label) +
                "can target the destination platform (e.g. the BCR llvm module); " +
                "none resolved for the current exec/target combination.",
            )
        fail(
            "{}: no C++ toolchain resolved for this native sdist build. ".format(ctx.label) +
            "Building native extensions requires a registered C++ toolchain " +
            "usable on the selected execution platform.",
        )

    wheel_file = ctx.actions.declare_file(ctx.label.name + ".whl")
    patch_args, patch_inputs = patch_args_and_inputs(ctx)

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

    cross_args = []
    if cross:
        cc_toolchain = cc_toolchain_raw
        if hasattr(cc_toolchain, "cc_provider_in_toolchain") and hasattr(cc_toolchain, "cc"):
            cc_toolchain = cc_toolchain.cc
        cc_layer = extract_cc_layer(ctx, cc_toolchain)

        # Toolchain flags first, then any flags the package set via `env`
        # (uv.override_package): the package's -D/-std/feature-baseline
        # additions must survive, and trailing position lets them override.
        # Values inherited from the ambient shell env stay excluded — only
        # an explicit `env` entry merges.
        for key, toolchain_flags in (
            ("CFLAGS", cc_layer.cflags),
            ("CXXFLAGS", cc_layer.cxxflags),
            ("LDFLAGS", cc_layer.ldflags),
            ("LDSHAREDFLAGS", cc_layer.ldshared_flags),
        ):
            if not toolchain_flags:
                continue
            package_flags = env.get(key) if key in ctx.attr.env else None
            env[key] = toolchain_flags + " " + package_flags if package_flags else toolchain_flags
        if cc_layer.ccshared:
            env["CFLAGS"] = (env.get("CFLAGS", "") + " " + cc_layer.ccshared).strip()
            env["CXXFLAGS"] = (env.get("CXXFLAGS", "") + " " + cc_layer.ccshared).strip()

        if cc_layer.static_runtime_files:
            extra_inputs.append(cc_layer.static_runtime_files)
        if cc_layer.static_runtime_paths:
            env["RULES_PY_CXX_STATIC_RUNTIME"] = ":".join(cc_layer.static_runtime_paths)

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
                artifacts = _target_python_artifacts(runtime)
                if artifacts.sysconfig:
                    extra_inputs.append(depset([artifacts.sysconfig]))
                    env["RULES_PY_TARGET_SYSCONFIGDATA"] = artifacts.sysconfig.path
                if artifacts.include_dir:
                    extra_inputs.append(depset(artifacts.include_files))
                    env["RULES_PY_TARGET_INCLUDE"] = artifacts.include_dir

        host_platform = _derive_python_host_platform(cc_layer.target_os, cc_layer.target_cpu)
        if host_platform:
            env["_PYTHON_HOST_PLATFORM"] = host_platform

    tool = ctx.attr.tool[DefaultInfo].files_to_run

    ctx.actions.run(
        mnemonic = "PySdistNativeBuild",
        progress_message = "Native source compiling {} to a whl".format(archive.basename),
        executable = tool,
        toolchain = None,
        arguments = ctx.attr.args + [patch_args] + memory_args(ctx) + cross_args + [
            "--execroot-marker",
            _EXECROOT_MARKER,
            archive.path,
            wheel_file.path,
        ],
        inputs = depset(
            [archive],
            transitive = [patch_inputs] + extra_inputs,
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

The build is guaranteed to occur on an execution platform matching the
constraints of the target platform.

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
    } | CC_LAYER_ATTRS,
    fragments = ["cpp"],
    toolchains = [
        # Target-configured interpreter, read only for its platform triple in
        # the cross detection; optional so unresolvable targets surface the
        # rule's own error instead of a toolchain-resolution one.
        config_common.toolchain_type(PY_TOOLCHAIN, mandatory = False),
    ],
    exec_groups = {
        # Cross-compilation of sdists is intentionally unsupported: PEP 517
        # build backends (setuptools, meson-python, etc.) have no standard
        # mechanism for cross-compilation, Python headers for the target
        # platform are not readily available, and output wheel tags would
        # need to encode the target platform with no upstream tooling
        # support. Packages that need cross-compiled native extensions should
        # publish pre-built wheels for their target platforms instead.
        #
        # Detection inputs: NATIVE_BUILD_TOOLCHAIN has matching
        # exec_compatible_with and target_compatible_with, so it resolves
        # exactly when the exec and target platforms match — optional, its
        # absence is a cross signal, not a resolution error. The exec- and
        # target-configured interpreters' platform triples refine that signal
        # (see _cross_decision); a cross decision switches the action into
        # cross mode (cc_layer extraction + target-identity env) instead of
        # failing.
        TARGET_EXEC_GROUP: exec_group(
            toolchains = [
                PY_TOOLCHAIN,
                config_common.toolchain_type(EXEC_TOOLS_TOOLCHAIN, mandatory = False),
                config_common.toolchain_type(NATIVE_BUILD_TOOLCHAIN, mandatory = False),
                # Optional for the same reason: on a cross target no C++
                # toolchain may resolve, and the rule's own error must win
                # over a resolution failure.
                config_common.toolchain_type(_CC_TOOLCHAIN_TYPE, mandatory = False),
            ],
        ),
    },
)
