load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")

_EXECROOT_MARKER = "__ASPECT_RULES_PY_EXECROOT__"

_CC_DISABLED_FEATURES = [
    "thin_lto",
    "module_maps",
    "fdo_instrument",
    "fdo_optimize",
    "layering_check",
]

_PATH_FLAG_PREFIXES = ("-I", "-L", "-isysroot", "-iwithsysroot", "-isystem", "-B")

CC_LAYER_ATTRS = {
    "_os_linux": attr.label(default = "@platforms//os:linux"),
    "_os_macos": attr.label(default = "@platforms//os:macos"),
    "_os_windows": attr.label(default = "@platforms//os:windows"),
    "_cpu_x86_64": attr.label(default = "@platforms//cpu:x86_64"),
    "_cpu_aarch64": attr.label(default = "@platforms//cpu:aarch64"),
    "_cpu_arm": attr.label(default = "@platforms//cpu:arm"),
    "_cpu_x86_32": attr.label(default = "@platforms//cpu:x86_32"),
}

def _absolutize_flag(flag):
    """Prefix execroot-relative paths with the EXECROOT marker.

    The marker is replaced with os.getcwd() at execution time by
    build_helper.py's _compiler_env, so paths survive the backend's
    chdir into the unpacked sdist worktree.
    """
    if not flag:
        return flag
    if not flag.startswith("-"):
        if "/" in flag and not flag.startswith("/"):
            return _EXECROOT_MARKER + "/" + flag
        return flag
    for pfx in _PATH_FLAG_PREFIXES:
        if flag.startswith(pfx) and len(flag) > len(pfx):
            rest = flag[len(pfx):]
            if rest and not rest.startswith("/") and "/" in rest:
                return pfx + _EXECROOT_MARKER + "/" + rest
    return flag

def get_target_platform(ctx):
    """Determine target OS and CPU from platform constraints.

    Returns Python-sysconfig-style names: (target_os, target_cpu).
    Each may be None if the target platform lacks a recognized constraint.
    """
    target_os = None
    target_cpu = None

    if ctx.target_platform_has_constraint(ctx.attr._os_linux[platform_common.ConstraintValueInfo]):
        target_os = "linux"
    elif ctx.target_platform_has_constraint(ctx.attr._os_macos[platform_common.ConstraintValueInfo]):
        target_os = "darwin"
    elif ctx.target_platform_has_constraint(ctx.attr._os_windows[platform_common.ConstraintValueInfo]):
        target_os = "windows"

    if ctx.target_platform_has_constraint(ctx.attr._cpu_x86_64[platform_common.ConstraintValueInfo]):
        target_cpu = "x86_64"
    elif ctx.target_platform_has_constraint(ctx.attr._cpu_aarch64[platform_common.ConstraintValueInfo]):
        target_cpu = "aarch64"
    elif ctx.target_platform_has_constraint(ctx.attr._cpu_arm[platform_common.ConstraintValueInfo]):
        target_cpu = "arm"
    elif ctx.target_platform_has_constraint(ctx.attr._cpu_x86_32[platform_common.ConstraintValueInfo]):
        target_cpu = "x86"

    return target_os, target_cpu

def extract_cc_layer(ctx, cc_toolchain):
    """Extract CC toolchain tools, flags, and target platform info.

    Called only in cross-compilation mode. The native path relies on the
    existing _cc_toolchain_inputs_and_tools + backend self-discovery.

    Args:
        ctx: The rule context. Must include CC_LAYER_ATTRS and
            fragments = ["cpp"].
        cc_toolchain: The resolved CcToolchainInfo-like object from
            ctx.exec_groups[_TARGET_EXEC_GROUP].toolchains[_CC_TOOLCHAIN_TYPE].

    Returns:
        struct(
            cc, cxx, ar       — tool execpaths,
            cflags, cxxflags  — joined compile flags (absolutized),
            ldflags           — joined executable linker flags (absolutized),
            ldshared_flags    — joined shared-lib linker flags (absolutized),
            ccshared          — "-fPIC" or "",
            target_os         — "linux" | "darwin" | "windows" | None,
            target_cpu        — "x86_64" | "aarch64" | "arm" | "x86" | None,
        )
    """
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features + _CC_DISABLED_FEATURES,
    )

    action_map = {
        "cc": ACTION_NAMES.c_compile,
        "cxx": ACTION_NAMES.cpp_compile,
        "ldshared": ACTION_NAMES.cpp_link_dynamic_library,
        "ld": ACTION_NAMES.cpp_link_executable,
        "ar": ACTION_NAMES.cpp_link_static_library,
    }

    tools = {}
    for key, action_name in action_map.items():
        if cc_common.action_is_enabled(
            feature_configuration = feature_configuration,
            action_name = action_name,
        ):
            tools[key] = cc_common.get_tool_for_action(
                feature_configuration = feature_configuration,
                action_name = action_name,
            )

    compile_vars = cc_common.create_compile_variables(
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
    )
    cxx_vars = cc_common.create_compile_variables(
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        add_legacy_cxx_options = True,
    )
    link_shared_vars = cc_common.create_link_variables(
        cc_toolchain = cc_toolchain,
        feature_configuration = feature_configuration,
        is_using_linker = True,
        is_linking_dynamic_library = True,
        must_keep_debug = False,
    )
    link_exe_vars = cc_common.create_link_variables(
        cc_toolchain = cc_toolchain,
        feature_configuration = feature_configuration,
        is_using_linker = True,
        is_linking_dynamic_library = False,
        must_keep_debug = False,
    )
    link_static_vars = cc_common.create_link_variables(
        cc_toolchain = cc_toolchain,
        feature_configuration = feature_configuration,
        is_using_linker = False,
        is_linking_dynamic_library = False,
        must_keep_debug = False,
    )

    vars_map = {
        "cc": compile_vars,
        "cxx": cxx_vars,
        "ldshared": link_shared_vars,
        "ld": link_exe_vars,
        "ar": link_static_vars,
    }

    flags = {}
    for key, action_name in action_map.items():
        if not cc_common.action_is_enabled(
            feature_configuration = feature_configuration,
            action_name = action_name,
        ):
            continue
        raw = cc_common.get_memory_inefficient_command_line(
            feature_configuration = feature_configuration,
            action_name = action_name,
            variables = vars_map[key],
        )
        flags[key] = " ".join([_absolutize_flag(f) for f in raw])

    needs_pic = cc_common.action_is_enabled(
        feature_configuration = feature_configuration,
        action_name = ACTION_NAMES.cpp_link_dynamic_library,
    )

    target_os, target_cpu = get_target_platform(ctx)

    # A "-nostdlib++" toolchain (the BCR llvm module) supplies its C++/unwind
    # runtime as toolchain *inputs* (static_runtime_lib), not as link-action
    # flags — get_memory_inefficient_command_line never sees them, so a PEP
    # 517 backend linking C++ through our wrappers produces .so's with
    # undefined std::__1/_Unwind_* symbols that only explode at dlopen time
    # on the target. Extract the archives so the wrapper can link them
    # explicitly. Only probed behind the -nostdlib++ marker: self-contained
    # drivers (gcc_toolchain) resolve their own runtime and may not define
    # static_runtime_lib at all, which would fail the API call.
    static_runtime_files = None
    static_runtime_paths = []
    if "-nostdlib++" in flags.get("ldshared", ""):
        static_runtime_files = cc_toolchain.static_runtime_lib(
            feature_configuration = feature_configuration,
        )
        static_runtime_paths = [
            _EXECROOT_MARKER + "/" + f.path
            for f in static_runtime_files.to_list()
            if f.path.endswith(".a")
        ]

    return struct(
        cc = tools.get("cc"),
        cxx = tools.get("cxx"),
        ar = tools.get("ar"),
        cflags = flags.get("cc", ""),
        cxxflags = flags.get("cxx", ""),
        ldflags = flags.get("ld", ""),
        ldshared_flags = flags.get("ldshared", ""),
        ccshared = "-fPIC" if needs_pic else "",
        target_os = target_os,
        target_cpu = target_cpu,
        static_runtime_files = static_runtime_files,
        static_runtime_paths = static_runtime_paths,
    )

# Exposed for the unit tests in tests/pep517_whl_test.bzl only.
cc_layer_test_util = struct(
    absolutize_flag = _absolutize_flag,
    execroot_marker = _EXECROOT_MARKER,
)
