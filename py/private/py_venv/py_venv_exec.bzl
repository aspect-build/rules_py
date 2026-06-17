"""Implementation for the py_venv_exec and py_venv_exec_test rules.

Both are thin launchers that consume a sibling `py_venv` (passed via the
internal `venv` attr) and exec its `bin/python`. The public
`py_binary` / `py_test` macros wrap them and route all venv-shaping
attrs to the auto-generated sibling.
"""

load("@bazel_lib//lib:expand_make_vars.bzl", "expand_locations", "expand_variables")
load("@hermetic_launcher//launcher:lib.bzl", "launcher")
load("@rules_python//python:defs.bzl", "PyInfo")
load("//py/private:py_semantics.bzl", _py_semantics = "semantics")
load(":types.bzl", "VirtualenvInfo")

# Identifiers the launcher always sets to the analysing rule's contextual
# values. Excluded from `inherited_environment` so that a stray
# `env_inherit` entry can't let an outer shell shadow the contextual
# label at run time.
_CONTEXTUAL_ENV_KEYS = ("BAZEL_TARGET", "BAZEL_WORKSPACE", "BAZEL_TARGET_NAME")

def _py_venv_exec_impl(ctx):
    # The launcher itself doesn't need a python toolchain — it executes
    # the sibling venv's runfiles-aware interpreter, whose path was already
    # resolved when the venv was analysed. Default interpreter flags come
    # from a shared constant.
    #
    # The macro layer routes srcs / deps to the sibling py_venv (always
    # set as `venv`) and passes an explicit `main =` to the rule.
    # `main` is the only first-party file the rule contributes;
    # everything else flows through the sibling venv.
    if not ctx.attr.main:
        fail("py_binary {}: main is required.".format(ctx.label))
    main = ctx.file.main
    if not main.basename.endswith(".py"):
        fail("main must end in '.py', got: " + main.basename)

    venv = ctx.attr.venv
    if not venv:
        fail("py_binary {}: venv is required.".format(ctx.label))
    vinfo = venv[VirtualenvInfo]

    # Merge env vars: start from the venv's `env` (if any), then
    # overlay the binary's own — binary wins on key conflicts. Same
    # merge for inherited env-var names. Bazel-contextual identifiers
    # (BAZEL_TARGET, etc.) overlay last and are stripped from
    # `inherited_env` so a stray `env_inherit` entry can't let the
    # caller's shell shadow the contextual label — per
    # https://bazel.build/rules/lib/providers/RunEnvironmentInfo, an
    # inherited value wins over `environment` when both are present.
    passed_env = {}
    inherited_env = []
    if RunEnvironmentInfo in venv:
        venv_env = venv[RunEnvironmentInfo]
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
    passed_env["BAZEL_TARGET"] = str(ctx.label).lstrip("@")
    passed_env["BAZEL_WORKSPACE"] = ctx.workspace_name
    passed_env["BAZEL_TARGET_NAME"] = ctx.attr.name
    inherited_env = [n for n in inherited_env if n not in _CONTEXTUAL_ENV_KEYS]

    # When `isolated = False`, drop Python's `-I` flag so PYTHONPATH is
    # honored and the script directory is auto-added to sys.path.
    flags = list(_py_semantics.interpreter_flags) + ctx.attr.interpreter_options
    if not ctx.attr.isolated:
        flags = [f for f in flags if f != "-I"]

    # Native launcher via hermetic_launcher. Embedded argv:
    #   [0]  venv's bin/python (runfiles-resolved)
    #   [1+] interpreter flags (literal, e.g. -I, -X importtime)
    #   [N]  main module path (runfiles-resolved)
    # The launcher runtime resolves transformed-arg positions through
    # the Bazel runfiles manifest, then `execve`s the venv python.
    executable_launcher = ctx.actions.declare_file(ctx.attr.name)
    embedded_args, transformed_args = launcher.args_from_entrypoint(vinfo.runtime_python)
    for flag in flags:
        embedded_args, transformed_args = launcher.append_embedded_arg(
            arg = flag,
            embedded_args = embedded_args,
            transformed_args = transformed_args,
        )
    embedded_args, transformed_args = launcher.append_runfile(
        file = main,
        embedded_args = embedded_args,
        transformed_args = transformed_args,
    )
    launcher.compile_stub(
        ctx = ctx,
        embedded_args = embedded_args,
        transformed_args = transformed_args,
        output_file = executable_launcher,
    )

    # Merge runfiles, supporting `py_venv_exec(main)` not being in the `py_venv` runfiles.
    runfiles = ctx.runfiles(
        files = ctx.files.data + [main],
    ).merge_all(
        [target[DefaultInfo].default_runfiles for target in ctx.attr.data] +
        [venv[DefaultInfo].default_runfiles],
    )

    instrumented_files_info = coverage_common.instrumented_files_info(
        ctx,
        source_attributes = ["main"],
        dependency_attributes = ["data", "venv"],
        extensions = ["py"],
    )

    return [
        DefaultInfo(
            files = depset([executable_launcher, main]),
            executable = executable_launcher,
            runfiles = runfiles,
        ),
        PyInfo(
            # Surface the venv's imports + transitive_sources through
            # PyInfo so downstream consumers (e.g. py_pex_binary's
            # `--sys-path=`) see the same sys.path / source closure the
            # launcher will run with. `srcs` / `deps` live on the
            # sibling venv, not on this rule.
            imports = vinfo.imports,
            transitive_sources = vinfo.transitive_sources,
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
    "venv": attr.label(
        providers = [[VirtualenvInfo]],
        mandatory = True,
        doc = """Internal: set by the `py_binary_with_venv` macro for
every public `py_binary` / `py_test` invocation (the macro splits the
call into a py_venv target + a rule call routed at it). Not a
user-facing attribute — direct settings on the rule are blocked at
the macro layer in `//py:defs.bzl`.

The binary's launcher exec's the referenced venv's runfiles-aware
interpreter; its runfiles inherit the venv's default_runfiles so all
wheels and first-party sources land at their usual rlocation paths.
""",
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
    # `data` is the only py_library attr the launcher reads (env-var
    # location expansion, runfiles merge, coverage walk). `srcs`,
    # `deps`, `imports`, `resolutions`, and `virtual_deps` are routed
    # to the sibling py_venv by the macro layer and have no role on
    # the launcher rule.
    "data": attr.label_list(
        doc = """Runtime dependencies of the program.

The transitive closure of the `data` dependencies will be available in
the `.runfiles` folder for this binary/test. The program may optionally
use the Runfiles lookup library to locate the data files, see
https://pypi.org/project/bazel-runfiles/.
""",
        allow_files = True,
    ),
    # Forwarded to the sibling py_venv (which is where srcs actually
    # feed sys.path). Carried on the launcher only so Bazel's `args`
    # location-expansion (`args = ["$(location :foo.py)"]`) can resolve
    # the label against the same files the user wrote on
    # `py_binary` / `py_test`.
    "srcs": attr.label_list(
        doc = "Python source files. Forwarded to the sibling py_venv.",
        allow_files = [".py"],
    ),
})

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

py_venv_exec = rule(
    doc = "Launcher rule that exec's the interpreter from a sibling `py_venv` (set via `venv`). Most users should use the [py_binary macro](#py_binary) instead of loading this directly.",
    implementation = _py_venv_exec_impl,
    attrs = _attrs,
    executable = True,
    toolchains = [launcher.finalizer_toolchain_type, launcher.template_toolchain_type],
)

py_venv_exec_test = rule(
    doc = "Test variant of `py_venv_exec`. Most users should use the [py_test macro](#py_test) instead of loading this directly.",
    implementation = _py_venv_exec_impl,
    attrs = _attrs | _test_attrs,
    test = True,
    toolchains = [launcher.finalizer_toolchain_type, launcher.template_toolchain_type],
)
