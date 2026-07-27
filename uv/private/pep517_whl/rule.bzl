"""
PEP 517 sdist-to-wheel build rules.

Uses `python -m build` (the pypa/build frontend) which delegates to whatever
build backend the sdist declares in its `[build-system]` table.
"""

load("@bazel_lib//lib:resource_sets.bzl", "resource_set", "resource_set_attr")
load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//py/private/toolchain:types.bzl", "NATIVE_BUILD_TOOLCHAIN", "PY_TOOLCHAIN")
load("//uv/private:source_built_wheel.bzl", "SourceBuiltWheelInfo")

_CC_TOOLCHAIN_TYPE = Label("@bazel_tools//tools/cpp:toolchain_type")
_TARGET_EXEC_GROUP = "target"
_EXECROOT_MARKER = "__ASPECT_RULES_PY_EXECROOT__"
_INFER_CXX_COMPANION = "ASPECT_RULES_PY_INFER_CXX_COMPANION"

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
        # Legacy C++ toolchains can omit action configs while still exposing
        # usable tools through CcToolchainInfo. Action-only providers may
        # fabricate these fields, so require each fallback to be an input.
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

def _library_display_name(lib):
    for artifact in (lib.static_library, lib.pic_static_library, lib.dynamic_library, lib.interface_library):
        if artifact:
            return artifact.basename
    return "<unknown>"

# cc_deps flattens a dependency's link inputs into setuptools' two slots: static
# archives and `-l<name>` entries go to the post-object [build_ext] slots, and
# every other link flag rides along in pre-object LDFLAGS. That split cannot
# preserve the relative order between an -l entry and a neighboring flag, so only
# flags whose effect does not depend on that order are safe to pass through.
#
# This is an allowlist of flag SHAPES, not a denylist of known-bad flags. A
# denylist against the open set of linker flags fails open: any order-sensitive
# flag we did not think to enumerate would be reordered silently into a stream
# that no longer links what the user wrote. The denylist this replaced had to
# grow twice under review for exactly that reason. An allowlist fails closed: an
# unrecognized flag is rejected at analysis, and the set can be widened later
# without breaking anyone, whereas a denylist can never be tightened.
#
# Each entry is (kind, token):
#   "exact"      the whole flag must equal token (e.g. -pthread)
#   "prefix"     the flag must start with token and carry a glued argument
#                (e.g. -Ldir)
#   "wl_arg"     a -Wl, directive that takes an argument, either as the next
#                comma segment (-Wl,-rpath,<path>) or glued with =
#                (-Wl,-rpath=<path>)
#   "wl_keyword" a -Wl, directive whose argument (next comma segment) must be
#                one of the reviewed keywords in ALLOWED_Z_KEYWORDS
#                (-Wl,-z,relro)
#   "wl_exact"   a -Wl, directive that stands alone (-Wl,--enable-new-dtags)
#
# -Wl, hands the linker a comma-joined list of directives, so a token whose
# leading directive is allowed could otherwise smuggle an order-sensitive
# directive behind it (-Wl,-rpath,/x,--as-needed). -Wl, tokens are therefore
# walked directive by directive and every directive must be allowed, which also
# keeps benign compounds like -Wl,-z,relro,-z,now working.
#
# -framework is deliberately absent: ld64 resolves frameworks in command-line
# order alongside -l entries (a framework is a library input, not a flag), so
# neither setuptools slot can hold one without reordering library resolution.
#
# Exported so the cc_deps test package pins it against a golden copy; a shape
# dropped here would otherwise drop its acceptance coverage silently.
ALLOWED_LINK_FLAG_SHAPES = (
    ("exact", "-pthread"),
    ("prefix", "-L"),
    ("wl_arg", "-rpath"),
    ("wl_arg", "-rpath-link"),
    ("wl_arg", "--version-script"),
    ("wl_keyword", "-z"),
    # --enable-new-dtags selects the global ELF dtags mode (DT_RUNPATH over
    # DT_RPATH); it is position-insensitive and commonly comma-joined after an
    # $ORIGIN rpath.
    ("wl_exact", "--enable-new-dtags"),
)

# Accepted -z keywords, each a global link mode. The -z namespace is open and
# contains position-sensitive keywords on some linkers (Solaris -z allextract
# toggles whole-archive extraction for the archives that follow it), so
# accepting the whole class would reintroduce the fail-open shape this
# allowlist exists to close. Keywords are reviewed individually; the set can
# be extended upstream on request. Golden-pinned by the cc_deps test package
# alongside the shapes.
ALLOWED_Z_KEYWORDS = (
    "relro",
    "now",
    "noexecstack",
    "origin",
)

_WL_ARG_DIRECTIVES = {token: True for kind, token in ALLOWED_LINK_FLAG_SHAPES if kind == "wl_arg"}
_WL_KEYWORD_DIRECTIVES = {token: True for kind, token in ALLOWED_LINK_FLAG_SHAPES if kind == "wl_keyword"}
_WL_EXACT_DIRECTIVES = {token: True for kind, token in ALLOWED_LINK_FLAG_SHAPES if kind == "wl_exact"}
_ALLOWED_Z_KEYWORDS = {keyword: True for keyword in ALLOWED_Z_KEYWORDS}

def _link_flag_allowed(flag):
    """Whether a bare (non-`-l`, non-`-Wl,`) flag matches an allowed shape."""
    for kind, token in ALLOWED_LINK_FLAG_SHAPES:
        if kind == "exact" and flag == token:
            return True
        if kind == "prefix" and flag.startswith(token) and len(flag) > len(token):
            return True
    return False

def _check_wl_link_flag(owner, flag):
    """Validate every directive in a comma-joined `-Wl,` token, or fail.

    Walks the comma segments as directive/argument pairs: an allowed argument
    directive consumes the next segment (or embeds its argument after `=`), a
    keyword directive consumes the next segment and checks it against the
    reviewed keyword set, and every directive in the token must be allowed.
    Validating only the leading directive would let it smuggle an
    order-sensitive directive behind it.
    """
    segments = flag.split(",")[1:]
    expect_arg = False
    keyword_directive = None
    last_directive = None
    for segment in segments:
        if expect_arg:
            expect_arg = False
            if keyword_directive != None and segment not in _ALLOWED_Z_KEYWORDS:
                _reject_link_flag(owner, flag, "{} {}".format(keyword_directive, segment))
            keyword_directive = None
            continue
        last_directive = segment
        if segment in _WL_EXACT_DIRECTIVES:
            continue
        if segment in _WL_KEYWORD_DIRECTIVES:
            expect_arg = True
            keyword_directive = segment
            continue
        if segment in _WL_ARG_DIRECTIVES:
            expect_arg = True
            continue
        eq = segment.find("=")
        if eq > 0 and eq < len(segment) - 1 and segment[:eq] in _WL_ARG_DIRECTIVES:
            continue
        _reject_link_flag(owner, flag, segment)
    if expect_arg:
        # A trailing argument directive with nothing to consume is malformed.
        _reject_link_flag(owner, flag, last_directive)

def _reject_link_flag(owner, flag, directive = None):
    if directive == None:
        offense = "passes the link flag {}, which is not one of the link-flag shapes cc_deps accepts".format(flag)
    else:
        offense = "passes the link flag {}; its directive {} is not one of the link-flag shapes cc_deps accepts".format(flag, directive)
    fail(("cc_deps dependency {} {}. cc_deps splits a dependency's link " +
          "inputs into pre-object LDFLAGS and the post-object [build_ext] libraries " +
          "slot, so only position-insensitive flags can ride along. For an archive " +
          "cycle, repeat the library name instead (e.g. -la -lb -la); order among " +
          "-l entries is preserved. For a global toggle such as --as-needed, set it " +
          "in the override's env LDFLAGS. For anything else, apply it with " +
          "pre_build_patches on the sdist. The accepted shapes can be extended " +
          "upstream on request.").format(owner, offense))

def _anchor_declared_paths(flag, declared_paths):
    """Marker-anchor any declared additional_input path appearing in `flag`.

    Substitution goes through per-path placeholders, longest path first, so a
    declared path that contains another declared path is never anchored twice.
    """
    for index, path in enumerate(declared_paths):
        flag = flag.replace(path, "\v{}\v".format(index))
    for index, path in enumerate(declared_paths):
        flag = flag.replace("\v{}\v".format(index), "{}/{}".format(_EXECROOT_MARKER, path))
    return flag

def _cc_deps_args_and_inputs(ctx):
    """Flatten `cc_deps` CcInfo into a compile/link params file for the backend.

    Returns `(args, direct_inputs, transitive_inputs)`. When `cc_deps` is empty
    all three are empty, so the action stays byte-identical to the no-cc_deps
    path. Every emitted path is prefixed with `_EXECROOT_MARKER`: only
    execroot-relative paths exist at analysis time, and build_helper substitutes
    the real execroot before the backend changes into the unpacked source tree.
    Slot information (post-object archives vs `-l` libraries vs order-insensitive
    flags) is kept distinct in the JSON schema because flattening it into `env`
    would lose it.
    """
    if not ctx.attr.cc_deps:
        return [], [], []

    cc_info = cc_common.merge_cc_infos(
        cc_infos = [dep[CcInfo] for dep in ctx.attr.cc_deps],
    )
    compilation_context = cc_info.compilation_context

    compile_flags = []
    for include in compilation_context.includes.to_list():
        compile_flags.append("-I{}/{}".format(_EXECROOT_MARKER, include))
    for include in compilation_context.quote_includes.to_list():
        compile_flags.append("-iquote{}/{}".format(_EXECROOT_MARKER, include))
    for include in compilation_context.system_includes.to_list():
        compile_flags.append("-isystem{}/{}".format(_EXECROOT_MARKER, include))

    # external_includes carries `-isystem` semantics; older Bazel lacks the field.
    external_includes = getattr(compilation_context, "external_includes", None)
    if external_includes:
        for include in external_includes.to_list():
            compile_flags.append("-isystem{}/{}".format(_EXECROOT_MARKER, include))

    # framework_includes carries Apple `-F` search paths; older Bazel lacks the field.
    framework_includes = getattr(compilation_context, "framework_includes", None)
    if framework_includes:
        for framework in framework_includes.to_list():
            compile_flags.append("-F{}/{}".format(_EXECROOT_MARKER, framework))
    for define in compilation_context.defines.to_list():
        compile_flags.append("-D{}".format(define))

    link_objects = []
    link_libraries = []
    link_flags = []
    archives = []
    additional_inputs = []
    for linker_input in cc_info.linking_context.linker_inputs.to_list():
        for lib in linker_input.libraries:
            if lib.alwayslink:
                fail(("cc_deps dependency {} contains alwayslink library {}; " +
                      "whole-archive linking is not supported.").format(
                    linker_input.owner,
                    _library_display_name(lib),
                ))
            archive = lib.pic_static_library or lib.static_library
            if not archive:
                fail(("cc_deps dependency {} provides no static archive (only a " +
                      "shared/dynamic library); the PEP 517 native build links " +
                      "static archives only. Provide a static or PIC-static " +
                      "library.").format(linker_input.owner))
            link_objects.append("{}/{}".format(_EXECROOT_MARKER, archive.path))
            archives.append(archive)

        # `-l<name>` from the dep's own linkopts routes to setuptools' libraries
        # slot; every other link flag must match an allowed shape (see
        # ALLOWED_LINK_FLAG_SHAPES) or the build is rejected at analysis. Paths of
        # files this linker_input declares via additional_inputs (e.g.
        # `-Wl,--version-script,$(location ...)`) are marker-anchored so they
        # survive the backend chdir.
        declared_paths = sorted(
            [f.path for f in linker_input.additional_inputs],
            key = len,
            reverse = True,
        )
        for flag in linker_input.user_link_flags:
            # The name carries no declared path, so -l routing precedes anchoring.
            if flag.startswith("-l") and len(flag) > 2:
                link_libraries.append(flag[len("-l"):])
                continue

            # -Wl, tokens are validated per directive so an allowed leading
            # directive cannot smuggle an order-sensitive one behind it.
            if flag.startswith("-Wl,"):
                _check_wl_link_flag(linker_input.owner, flag)
            elif not _link_flag_allowed(flag):
                _reject_link_flag(linker_input.owner, flag)

            link_flags.append(_anchor_declared_paths(flag, declared_paths))
        additional_inputs.extend(linker_input.additional_inputs)

    params = ctx.actions.declare_file("cc_deps_info.json")
    ctx.actions.write(
        output = params,
        content = json.encode({
            "compile_flags": compile_flags,
            "link_objects": link_objects,
            "link_libraries": link_libraries,
            "link_flags": link_flags,
        }),
    )

    return (
        ["--cc-deps-info", params.path],
        [params] + additional_inputs,
        [compilation_context.headers, depset(archives)],
    )

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

    cc_deps_args, cc_deps_direct, cc_deps_transitive = _cc_deps_args_and_inputs(ctx)

    ctx.actions.run(
        mnemonic = "PySdistNativeBuild",
        progress_message = "Native source compiling {} to a whl".format(archive.basename),
        executable = ctx.executable.tool,
        toolchain = None,
        arguments = ctx.attr.args + patch_args + _memory_args(ctx) + cc_deps_args + [
            "--execroot-marker",
            _EXECROOT_MARKER,
            archive.path,
            wheel_dir.path,
        ],
        inputs = depset(
            [archive] + patch_inputs + cc_deps_direct,
            transitive = extra_inputs + cc_deps_transitive,
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
        "cc_deps": attr.label_list(
            providers = [[CcInfo]],
            doc = "C++ libraries whose headers and static archives are made " +
                  "available to the build backend. Each target's `CcInfo` " +
                  "compilation context (include paths and defines) and linking " +
                  "context (static archives and link flags) are flattened into a " +
                  "params file consumed by the backend; execroot-relative paths " +
                  "are anchored with an internal execroot marker so they survive " +
                  "the backend changing into the unpacked source tree. Link flags " +
                  "referencing files a dependency declares via " +
                  "`additional_linker_inputs` are anchored the same way; a " +
                  "relative path not declared there passes through verbatim and " +
                  "will not resolve after the backend changes directory. Composes " +
                  "additively with `env`. Only static (or PIC-static) archives " +
                  "are supported; shared/dynamic and alwayslink libraries fail at " +
                  "analysis time. Only the setuptools build backend is supported; " +
                  "an sdist declaring any other build-backend is rejected when the " +
                  "wheel is built.",
        ),
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
