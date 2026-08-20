"""
PEP 517 sdist-to-wheel build rules.

Uses `python -m build` (the pypa/build frontend) which delegates to whatever
build backend the sdist declares in its `[build-system]` table.
"""

load("@bazel_tools//tools/cpp:toolchain_utils.bzl", find_cc_toolchain = "find_cpp_toolchain")
load("@rules_cc//cc:action_names.bzl", "CPP_COMPILE_ACTION_NAME", "C_COMPILE_ACTION_NAME")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("//py/private/toolchain:types.bzl", "NATIVE_BUILD_TOOLCHAIN", "PY_TOOLCHAIN")

CC_TOOLCHAIN = "@bazel_tools//tools/cpp:toolchain_type"

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

def _pep517_whl(ctx):
    archive = ctx.attr.src[DefaultInfo].files.to_list()[0]
    wheel_dir = ctx.actions.declare_directory("whl")
    patch_args, patch_inputs = _patch_args_and_inputs(ctx)

    # The build tool is a py_venv_binary wrapping build_helper.py. Using it as
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
    )

    return [DefaultInfo(files = depset([wheel_dir]))]

def _native_input_args_and_depsets(ctx):
    """Derives explicit build flags and action inputs from native_inputs targets.

    CcInfo targets contribute their compilation context (headers as inputs;
    include dirs and defines as flags) and the static libraries or object
    files of their linking context. Flag decisions are made here, in Starlark,
    from provider data — build_helper.py only absolutizes the paths it is
    handed (they are exec-root relative and the helper cds into the extracted
    source tree).

    Targets without CcInfo contribute their files verbatim; the helper exposes
    their paths via $PY_NATIVE_INPUT_PATHS for the build backend to consume
    explicitly.

    Returns (args, transitive_input_depsets) where args is an Args object.
    """
    args = ctx.actions.args()
    args.use_param_file("@%s")
    args.set_param_file_format("multiline")
    transitive = []

    cc_infos = [target[CcInfo] for target in ctx.attr.native_inputs if CcInfo in target]
    if cc_infos:
        compilation_context = cc_common.merge_cc_infos(cc_infos = cc_infos).compilation_context
        transitive.append(compilation_context.headers)
        args.add_all(compilation_context.includes, format_each = "--native-include=%s", uniquify = True)
        args.add_all(compilation_context.quote_includes, format_each = "--native-quote-include=%s", uniquify = True)
        args.add_all(compilation_context.system_includes, format_each = "--native-system-include=%s", uniquify = True)
        if hasattr(compilation_context, "external_includes"):
            args.add_all(compilation_context.external_includes, format_each = "--native-system-include=%s", uniquify = True)
        args.add_all(compilation_context.defines, format_each = "--native-define=%s", uniquify = True)

    # Dicts as ordered sets: dedupe across targets while keeping stable order.
    # This loop stays per-target (not merged) for per-target error attribution.
    static_libs = {}
    link_objects = {}

    for target in ctx.attr.native_inputs:
        if CcInfo not in target:
            files = target[DefaultInfo].files
            transitive.append(files)
            args.add_all(files, format_each = "--native-input-file=%s")
            continue

        target_has_linkable = False
        shared_only_library = None
        for linker_input in target[CcInfo].linking_context.linker_inputs.to_list():
            for library in linker_input.libraries:
                static_library = library.pic_static_library or library.static_library

                # Older Bazel doesn't expose the objects fields on LibraryToLink.
                objects = getattr(library, "pic_objects", None) or getattr(library, "objects", None)
                if static_library:
                    static_libs[static_library] = None
                    target_has_linkable = True
                elif objects:
                    for obj in objects:
                        link_objects[obj] = None
                    target_has_linkable = True
                elif library.dynamic_library or library.interface_library:
                    shared_only_library = library.dynamic_library or library.interface_library

        if shared_only_library and not target_has_linkable:
            # A wheel linked against a Bazel-built shared library would
            # import-fail at runtime: the venv carries no rpath into
            # bazel-out and we don't install the .so.
            fail(("native_inputs target '{}' (for {}) provides only shared " +
                  "libraries (e.g. '{}'). Sdist builds can only link against " +
                  "static libraries; runtime resolution of Bazel-managed shared " +
                  "libraries from an installed wheel is unsupported. " +
                  "Provide a static variant (e.g. cc_library, which always " +
                  "emits an archive).").format(
                target.label,
                ctx.label,
                shared_only_library.basename,
            ))

    args.add_all(static_libs.keys(), format_each = "--native-static-lib=%s")
    args.add_all(link_objects.keys(), format_each = "--native-link-object=%s")
    if static_libs:
        transitive.append(depset(static_libs.keys()))
    if link_objects:
        transitive.append(depset(link_objects.keys()))

    return args, transitive

def _pep517_native_whl(ctx):
    archive = ctx.attr.src[DefaultInfo].files.to_list()[0]
    wheel_dir = ctx.actions.declare_directory("whl")
    patch_args, patch_inputs = _patch_args_and_inputs(ctx)
    native_input_args, native_input_depsets = _native_input_args_and_depsets(ctx)

    env = _common_env(ctx)
    extra_inputs = native_input_depsets

    # Resolve the CC toolchain so setuptools/distutils can find the compiler
    # rather than falling back to whatever is on the system PATH.
    cc_toolchain = find_cc_toolchain(ctx, mandatory = False)
    if cc_toolchain:
        feature_configuration = cc_common.configure_features(
            ctx = ctx,
            cc_toolchain = cc_toolchain,
        )
        c_compiler_path = cc_common.get_tool_for_action(
            feature_configuration = feature_configuration,
            action_name = C_COMPILE_ACTION_NAME,
        )
        cpp_compiler_path = cc_common.get_tool_for_action(
            feature_configuration = feature_configuration,
            action_name = CPP_COMPILE_ACTION_NAME,
        )

        # Note that these paths are relative to the bazel exec root,
        # and they need to be absolutized if they're to be invoked from any
        # other working directory. (e.g. in build_helper.py for sdist builds.)
        env["CC"] = c_compiler_path

        # distutils compiles C++ sources with $CXX, falling back to a bare
        # `clang++`/`g++` from PATH which doesn't exist in the sandbox.
        env["CXX"] = cpp_compiler_path
        extra_inputs.append(cc_toolchain.all_files)

        # We can extract the relative path to the @llvm-provided sysroot from
        # the list of include directories.
        # It still needs to be absolutized, so we can't add it directly to
        # CFLAGS here.
        for c in cc_toolchain.built_in_include_directories:
            if c.endswith("sysroot"):
                env["SYSROOT"] = c
                break

    ctx.actions.run(
        mnemonic = "PySdistNativeBuild",
        progress_message = "Native source compiling {} to a whl".format(archive.basename),
        executable = ctx.executable.tool,
        toolchain = None,
        arguments = ctx.attr.args + patch_args + [
            native_input_args,
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
    "src": attr.label(),
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

The CC toolchain is resolved and `$CC` is set in the build environment so
that setuptools/distutils can find the hermetic compiler rather than falling
back to whatever is on the system PATH.

The build is guaranteed to occur on an execution platform matching the
constraints of the target platform.

""",
    attrs = _pep517_whl_attrs | {
        "args": attr.string_list(),
        "native_inputs": attr.label_list(
            default = [],
            allow_files = True,
            doc = "Bazel targets providing native build-time inputs. Targets with " +
                  "CcInfo contribute headers, include paths, defines, and static " +
                  "libraries to the compile/link environment; shared-library-only " +
                  "targets are rejected (wheels cannot resolve Bazel-managed shared " +
                  "libraries at runtime). Targets without CcInfo have their files " +
                  "staged into the action sandbox and exposed via " +
                  "$PY_NATIVE_INPUT_PATHS.",
        ),
        "_cc_toolchain": attr.label(
            default = Label("@bazel_tools//tools/cpp:current_cc_toolchain"),
        ),
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
                CC_TOOLCHAIN,
            ],
        ),
    },
    toolchains = [
        config_common.toolchain_type(CC_TOOLCHAIN, mandatory = False),
    ],
    fragments = ["cpp"],
)
