"""Implementation for the py_venv_exec and py_venv_exec_test rules.

Both are thin launchers that consume a sibling ``py_venv`` (passed via
the internal ``venv`` attr) and exec its ``bin/python``. The public
``py_binary`` / ``py_test`` macros wrap them and route all venv-shaping
attrs to the auto-generated sibling.
"""

load("@bazel_lib//lib:expand_make_vars.bzl", "expand_locations", "expand_variables")
load("@hermetic_launcher//launcher:lib.bzl", "launcher")
load("//py/private:py_info.bzl", "PyInfo")
load("//py/private:py_semantics.bzl", _py_semantics = "semantics")
load("//py/private:transitions.bzl", "reset_python_flags_transition")
load(":types.bzl", "VirtualenvInfo", "venv_root")

_CONTEXTUAL_ENV_KEYS = ("BAZEL_TARGET", "BAZEL_WORKSPACE", "BAZEL_TARGET_NAME")

def _validate_main(ctx):
    """Return the main module ``File``, failing if absent or not ``.py``."""
    main = ctx.file.main
    if not main:
        fail("py_binary {}: main is required.".format(ctx.label))
    if not main.basename.endswith(".py"):
        fail("main must end in '.py', got: " + main.basename)
    return main

def _set_contextual_env(ctx, passed_env):
    """Set Bazel contextual identifiers that always override user env."""
    passed_env["BAZEL_TARGET"] = str(ctx.label).lstrip("@")
    passed_env["BAZEL_WORKSPACE"] = ctx.workspace_name
    passed_env["BAZEL_TARGET_NAME"] = ctx.attr.name

def _strip_contextual_from_inherited(inherited_env):
    """Remove contextual keys so a stray ``env_inherit`` can't shadow them.

    Per RunEnvironmentInfo semantics, an inherited value wins over
    ``environment`` when both are present — stripping here prevents
    the caller's shell from overriding the contextual identifiers.
    """
    return [n for n in inherited_env if n not in _CONTEXTUAL_ENV_KEYS]

def _merge_environment(ctx, venv, vinfo):
    """Merge env vars from the sibling venv, the binary, and contextual keys.

    Precedence (last wins): venv ``RunEnvironmentInfo`` -> ``VIRTUAL_ENV``
    -> binary ``env`` -> contextual keys.  Returns
    ``(passed_env, inherited_env)``.
    """
    passed_env = {}
    inherited_env = []
    if RunEnvironmentInfo in venv:
        venv_env = venv[RunEnvironmentInfo]
        passed_env = dict(venv_env.environment)
        inherited_env = list(venv_env.inherited_environment)

    if "VIRTUAL_ENV" in ctx.attr.env:
        fail("py_binary/py_test {}: `VIRTUAL_ENV` is set by the rule and cannot be overridden via `env`.".format(ctx.label))

    passed_env["VIRTUAL_ENV"] = venv_root(vinfo.bin_python)
    for k, v in ctx.attr.env.items():
        passed_env[k] = expand_variables(
            ctx,
            expand_locations(ctx, v, ctx.attr.data),
            attribute_name = "env",
        )

    inherited_set = {n: True for n in inherited_env}
    for name in ctx.attr.env_inherit:
        if name not in inherited_set:
            inherited_env.append(name)
            inherited_set[name] = True

    _set_contextual_env(ctx, passed_env)
    inherited_env = _strip_contextual_from_inherited(inherited_env)

    return passed_env, inherited_env

def _interpreter_flags(ctx):
    """Build the interpreter flag list.

    Base flags come from ``py_semantics``.  When ``isolated = False``,
    ``-I`` is stripped from the **base** flags so PYTHONPATH is honored.
    User ``interpreter_options`` are always appended verbatim — a user
    explicitly passing ``-I`` survives the isolated-stripping.
    """
    base = list(_py_semantics.interpreter_flags)
    if not ctx.attr.isolated:
        base = [f for f in base if f != "-I"]
    return base + list(ctx.attr.interpreter_options)

def _build_launcher(ctx, vinfo, flags, main):
    """Compile the native launcher stub via ``hermetic_launcher``.

    Embedded argv: venv's ``bin/python``, interpreter flags, then the
    main module path.  The launcher runtime resolves runfiles positions
    and ``execve``'s the venv python.
    """
    executable = ctx.actions.declare_file(ctx.attr.name)
    embedded_args, transformed_args = launcher.args_from_entrypoint(vinfo.bin_python)
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
        output_file = executable,
    )
    return executable

def _build_runfiles(ctx, venv, main):
    """Merge data files, the main module, and the venv's runfiles."""
    return ctx.runfiles(
        files = ctx.files.data + [main],
    ).merge_all(
        [target[DefaultInfo].default_runfiles for target in ctx.attr.data] +
        [venv[DefaultInfo].default_runfiles],
    )

def _py_venv_exec_impl(ctx):
    main = _validate_main(ctx)
    venv = ctx.attr.venv
    vinfo = venv[VirtualenvInfo]

    passed_env, inherited_env = _merge_environment(ctx, venv, vinfo)
    flags = _interpreter_flags(ctx)
    executable = _build_launcher(ctx, vinfo, flags, main)
    runfiles = _build_runfiles(ctx, venv, main)

    return [
        DefaultInfo(
            files = depset([executable, main]),
            executable = executable,
            runfiles = runfiles,
        ),
        PyInfo(
            imports = vinfo.imports,
            transitive_sources = vinfo.transitive_sources,
            has_py2_only_sources = False,
            has_py3_only_sources = True,
            uses_shared_libraries = False,
        ),
        coverage_common.instrumented_files_info(
            ctx,
            source_attributes = ["main"],
            dependency_attributes = ["data", "venv"],
            extensions = ["py"],
        ),
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
    "env_inherit": attr.string_list(
        doc = "Names of environment variables to pass through from the invoking environment.",
        default = [],
    ),
    "main": attr.label(
        allow_single_file = True,
        mandatory = True,
        doc = "Python source file to execute. The macro layer resolves this from `srcs` when not set explicitly.",
    ),
    "venv": attr.label(
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
    "data": attr.label_list(
        doc = """Runtime dependencies of the program.

The transitive closure of the `data` dependencies will be available in
the `.runfiles` folder for this binary/test. The program may optionally
use the Runfiles lookup library to locate the data files, see
https://pypi.org/project/bazel-runfiles/.
Data is analyzed in the inherited caller configuration. Put artifacts
that must match the terminal's Python environment in `deps`.
""",
        allow_files = True,
        cfg = reset_python_flags_transition,
    ),
    "srcs": attr.label_list(
        doc = """Python source files. Forwarded to the sibling py_venv where
they feed sys.path. Carried on the launcher so that Bazel's `args`
location-expansion (`args = ["$(location :foo.py)"]`) can resolve the
label. The files reach runfiles transitively through the venv's
default_runfiles, not from this attribute directly.""",
        allow_files = [".py"],
    ),
    "_allowlist_function_transition": attr.label(
        default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
    ),
})

_test_attrs = dict({
    "_lcov_merger": attr.label(
        default = configuration_field(fragment = "coverage", name = "output_generator"),
        executable = True,
        cfg = "exec",
        doc = """Coverage output generator for `--combined_report`.

Required by Bazel's `collect_coverage.sh` (L186-194 of the script at
https://github.com/bazelbuild/bazel/blob/fde4b67/tools/test/collect_coverage.sh).
Only needed on the test variant, not the binary.""",
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
