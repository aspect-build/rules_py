"""Implementation for the py_binary and py_test rules."""

load("@bazel_lib//lib:expand_make_vars.bzl", "expand_locations", "expand_variables")
load("@bazel_lib//lib:paths.bzl", "BASH_RLOCATION_FUNCTION", "to_rlocation_path")
load("@rules_python//python:defs.bzl", "PyInfo")
load("//py/private:py_library.bzl", _py_library = "py_library_utils")
load("//py/private:py_semantics.bzl", _py_semantics = "semantics")
load("//py/private/py_venv:types.bzl", "VirtualenvInfo")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN")
load(":transitions.bzl", "python_version_transition")

def _dict_to_exports(env):
    return [
        "export %s=\"%s\"" % (k, v)
        for (k, v) in env.items()
    ]

def _py_binary_rule_impl(ctx):
    py_toolchain = _py_semantics.resolve_toolchain(ctx)

    # The macro layer routes srcs / deps to the sibling py_venv (always
    # set as `external_venv`) and passes an explicit `main =` to the
    # rule. `main` is the only first-party file the rule contributes;
    # everything else flows through the sibling venv.
    if not ctx.attr.main:
        fail("py_binary {}: main is required.".format(ctx.label))
    main = ctx.file.main
    if not main.basename.endswith(".py"):
        fail("main must end in '.py', got: " + main.basename)

    external_venv = ctx.attr.external_venv
    if not external_venv:
        fail("py_binary {}: external_venv is required.".format(ctx.label))
    vinfo = external_venv[VirtualenvInfo]

    # Bazel-contextual env vars that the launcher exports via
    # {{PYTHON_ENV}}.
    default_env = {
        "BAZEL_TARGET": str(ctx.label).lstrip("@"),
        "BAZEL_WORKSPACE": ctx.workspace_name,
        "BAZEL_TARGET_NAME": ctx.attr.name,
    }

    # Merge env vars: start from the venv's `env` (if any), then
    # overlay the binary's own — binary wins on key conflicts. Same
    # merge for inherited env-var names.
    passed_env = {}
    inherited_env = []
    if RunEnvironmentInfo in external_venv:
        venv_env = external_venv[RunEnvironmentInfo]
        passed_env = dict(venv_env.environment)
        inherited_env = list(venv_env.inherited_environment)
    for k, v in ctx.attr.env.items():
        passed_env[k] = expand_variables(
            ctx,
            expand_locations(ctx, v, ctx.attr.data),
            attribute_name = "env",
        )
    for name in getattr(ctx.attr, "env_inherit", []):
        if name not in inherited_env:
            inherited_env.append(name)

    # When `isolated = False`, drop Python's `-I` flag so PYTHONPATH is
    # honored and the script directory is auto-added to sys.path.
    flags = py_toolchain.flags + ctx.attr.interpreter_options
    if not ctx.attr.isolated:
        flags = [f for f in flags if f != "-I"]

    executable_launcher = ctx.actions.declare_file(ctx.attr.name)
    ctx.actions.expand_template(
        template = ctx.file._run_tmpl,
        output = executable_launcher,
        substitutions = {
            "{{BASH_RLOCATION_FN}}": BASH_RLOCATION_FUNCTION,
            "{{INTERPRETER_FLAGS}}": " ".join(flags),
            "{{ARG_VENV_PYTHON}}": to_rlocation_path(ctx, vinfo.bin_python),
            "{{ENTRYPOINT}}": to_rlocation_path(ctx, main),
            "{{PYTHON_ENV}}": "\n".join(_dict_to_exports(default_env)).strip(),
        },
        is_executable = True,
    )

    runfiles = _py_library.make_merged_runfiles(
        ctx,
        extra_depsets = [py_toolchain.files],
        extra_runfiles = [main],
        extra_runfiles_depsets = [
            ctx.attr._runfiles_lib[DefaultInfo].default_runfiles,
            external_venv[DefaultInfo].default_runfiles,
        ],
    )

    instrumented_files_info = coverage_common.instrumented_files_info(
        ctx,
        source_attributes = ["main"],
        dependency_attributes = ["data", "external_venv"],
        extensions = ["py"],
    )

    return [
        DefaultInfo(
            files = depset([executable_launcher, main]),
            executable = executable_launcher,
            runfiles = runfiles,
        ),
        PyInfo(
            # Surface the venv's imports through PyInfo so downstream
            # consumers (e.g. py_pex_binary's `--sys-path=`) see the
            # same sys.path the launcher will run with.
            imports = vinfo.imports,
            # No `srcs` / `deps` on this rule — first-party sources
            # live on the sibling venv. Keep the depset empty here.
            transitive_sources = depset(),
            has_py2_only_sources = False,
            has_py3_only_sources = True,
            uses_shared_libraries = False,
        ),
        instrumented_files_info,
        RunEnvironmentInfo(
            environment = passed_env,
            inherited_environment = inherited_env,
        ),
    ]

_attrs = dict({
    "env": attr.string_dict(
        doc = "Environment variables to set when running the binary.",
        default = {},
    ),
    "main": attr.label(
        allow_single_file = True,
        doc = """
Script to execute with the Python interpreter.

Must be a label pointing to a `.py` source file.
If such a label is provided, it will be honored.

If no label is provided AND there is only one `srcs` file, that `srcs` file will be used.

If there are more than one `srcs`, a file matching `{name}.py` is searched for.
This is for historical compatibility with the Bazel native `py_binary` and `rules_python`.
Relying on this behavior is STRONGLY discouraged, may produce warnings and may
be deprecated in the future.

""",
    ),
    "venv": attr.string(
        doc = """The name of the Python virtual environment within which deps should be resolved.

Part of the aspect_rules_py//uv system, has no effect in rules_python's pip.
""",
    ),
    "external_venv": attr.label(
        providers = [[VirtualenvInfo]],
        mandatory = True,
        doc = """Internal: set by the `py_binary_with_venv` macro for
every public `py_binary` / `py_test` invocation (the macro splits the
call into a py_venv target + a rule call routed at it). Not a
user-facing attribute — direct settings on the rule are blocked at
the macro layer in `//py:defs.bzl`.

The binary's launcher exec's the referenced venv's `bin/python`; its
runfiles inherit the venv's default_runfiles so all wheels and first-
party sources land at their usual rlocation paths.
""",
    ),
    "python_version": attr.string(
        doc = """Whether to build this target and its transitive deps for a specific python version.""",
    ),
    "interpreter_options": attr.string_list(
        doc = "Additional options to pass to the Python interpreter in addition to -B and -I passed by rules_py",
        default = [],
    ),
    "isolated": attr.bool(
        default = True,
        doc = """When True (default), the launcher invokes Python with `-I`
(isolated mode: ignore PYTHON* env vars, skip user site-packages, don't
auto-add the script's dir to sys.path). Set to False to drop `-I` — the
launcher then respects `PYTHONPATH` and loads user site-packages if the
sibling venv has `include_user_site_packages = True` set. The deprecated
`py_venv_binary` / `py_venv_test` aliases default this to False to
match their historical permissive behaviour.""",
    ),
    "_run_tmpl": attr.label(
        allow_single_file = True,
        default = "//py/private:run.tmpl.sh",
    ),
    "_runfiles_lib": attr.label(
        default = "@bazel_tools//tools/bash/runfiles",
    ),
    # Read by py_semantics — freethreaded interpreters live at
    # `lib/python<M>.<m>t/site-packages/`, not the default
    # `.../python<M>.<m>/`. Even though the rule no longer assembles a
    # venv, py_semantics.resolve_toolchain still consults this flag.
    "_freethreaded_flag": attr.label(
        default = "//py/private/interpreter:freethreaded",
    ),
    # Required for py_version attribute
    "_allowlist_function_transition": attr.label(
        default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
    ),
})

_attrs.update(**_py_library.attrs)

# `srcs` and `deps` are not rule-level attrs — the public macros route
# both to the sibling py_venv. Pop them after pulling py_library's attr
# dict so the rule rejects direct settings.
_attrs.pop("srcs", None)
_attrs.pop("deps", None)

_test_attrs = dict({
    "env_inherit": attr.string_list(
        doc = "Specifies additional environment variables to inherit from the external environment when the test is executed by bazel test.",
        default = [],
    ),
    # Magic attribute to make coverage --combined_report flag work.
    # There's no docs about this.
    # See https://github.com/bazelbuild/bazel/blob/fde4b67009d377a3543a3dc8481147307bd37d36/tools/test/collect_coverage.sh#L186-L194
    # NB: rules_python ALSO includes this attribute on the py_binary rule, but we think that's a mistake.
    # see https://github.com/aspect-build/rules_py/pull/520#pullrequestreview-2579076197
    "_lcov_merger": attr.label(
        default = configuration_field(fragment = "coverage", name = "output_generator"),
        executable = True,
        cfg = "exec",
    ),
})

py_base = struct(
    implementation = _py_binary_rule_impl,
    attrs = _attrs,
    test_attrs = _test_attrs,
    toolchains = [
        PY_TOOLCHAIN,
    ],
    cfg = python_version_transition,
)

py_binary = rule(
    doc = "Run a Python program under Bazel. Most users should use the [py_binary macro](#py_binary) instead of loading this directly.",
    implementation = py_base.implementation,
    attrs = py_base.attrs,
    toolchains = py_base.toolchains,
    executable = True,
    cfg = py_base.cfg,
)

py_test = rule(
    doc = "Run a Python program under Bazel. Most users should use the [py_test macro](#py_test) instead of loading this directly.",
    implementation = py_base.implementation,
    attrs = py_base.attrs | py_base.test_attrs,
    toolchains = py_base.toolchains,
    test = True,
    cfg = py_base.cfg,
)
