"""PEP 517 sdist to platform-specific whl build rule.

Uses `python -m build` (the pypa/build frontend) which delegates to whatever
build backend the sdist declares in its `[build-system]` table.
"""

load("@bazel_lib//lib:resource_sets.bzl", "resource_set")
load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("//py/private/interpreter:versions.bzl", "PLATFORMS")
load("//py/private/toolchain:types.bzl", "EXEC_TOOLS_TOOLCHAIN", "NATIVE_BUILD_TOOLCHAIN", "PY_TOOLCHAIN")
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

def _pep517_native_whl(ctx):
    archive = ctx.file.src

    eg_toolchains = ctx.exec_groups[TARGET_EXEC_GROUP].toolchains
    cross, exec_triple, target_triple = _cross_compile(ctx, eg_toolchains)
    if cross:
        detail = ""
        if exec_triple and target_triple:
            detail = " (execution platform interpreter: {}, target interpreter: {})".format(exec_triple, target_triple)
        fail(
            "{}: building this sdist would cross-compile its native extensions{}. ".format(ctx.label, detail) +
            "Cross-compilation of sdists is not supported: build on an execution " +
            "platform matching the target platform, or supply a prebuilt wheel " +
            "for the target instead of building from source.",
        )

    # Native build classified: a missing C++ toolchain must stay an explicit
    # analysis error (it used to be a resolution failure when the type was
    # mandatory) — otherwise the backend compiles with whatever ambient
    # compiler the sandbox exposes, or fails at execution time.
    if eg_toolchains[_CC_TOOLCHAIN_TYPE] == None:
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

    ctx.actions.run(
        mnemonic = "PySdistNativeBuild",
        progress_message = "Native source compiling {} to a whl".format(archive.basename),
        executable = ctx.executable.tool,
        toolchain = None,
        arguments = ctx.attr.args + patch_args + memory_args(ctx) + [
            "--execroot-marker",
            _EXECROOT_MARKER,
            archive.path,
            wheel_file.path,
        ],
        inputs = depset(
            [archive] + patch_inputs,
            transitive = extra_inputs,
        ),
        tools = [ctx.attr.tool[DefaultInfo].files_to_run],
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
    },
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
        # (see _cross_decision). The rule fails with an explicit message
        # instead of the toolchain-resolution error it used to surface.
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
