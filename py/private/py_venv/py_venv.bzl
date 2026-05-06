"""Implementation for the `py_venv` rule + `py_venv_link` and `py_binary_with_venv` macros.

- `py_venv` — a rule that builds a Python virtualenv and produces an
  executable that activates it and exec's `bin/python`. Emits
  `VirtualenvInfo` consumed by `py_binary_with_venv` (the
  `expose_venv = True` codepath). `bazel run :name` on a py_venv drops
  into the hermetic interpreter with the venv activated — useful for
  interactive Python sessions.

- `py_binary_with_venv` — shared helper invoked by
  `py_binary(expose_venv = True, ...)` / `py_test(expose_venv = True, ...)`.
  Splits the call into a sibling `:<name>.venv` `py_venv` + a
  `py_binary` / `py_test` rule that consumes it via the internal
  `external_venv` attribute. `bazel run :<name>.venv` drops into the
  interpreter.

- `py_venv_link` — opt-in macro that emits a runnable target whose
  `bazel run` materialises a workspace-local symlink to an existing
  `py_venv`'s tree. Pair with `py_binary(expose_venv = True)` to hand
  your IDE a stable `.venv` symlink to point at.

Shared venv-assembly logic lives in
`//py/private:venv.bzl::assemble_venv`. See that file's header for the
layout details.
"""

load("@bazel_lib//lib:expand_make_vars.bzl", "expand_locations", "expand_variables")
load("@bazel_lib//lib:paths.bzl", "BASH_RLOCATION_FUNCTION", "to_rlocation_path")
load("//py/private:py_library.bzl", _py_library = "py_library_utils")
load("//py/private:py_semantics.bzl", _py_semantics = "semantics")
load("//py/private:transitions.bzl", "python_version_transition")
load("//py/private:venv.bzl", "assemble_venv")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN")
load(":types.bzl", "VirtualenvInfo")

def _interpreter_flags(ctx, include_main = False):
    py_toolchain = _py_semantics.resolve_toolchain(ctx)
    args = py_toolchain.flags + ctx.attr.interpreter_options

    # py_venv strips `-I` so the interpreter picks up PYTHONPATH and
    # script dir — useful when users `bazel run` the venv for an
    # interactive python session and want their shell's env to apply.
    # The per-binary py_binary launcher keeps `-I` (see py_binary.bzl).
    args = [it for it in args if it not in ["-I"]]

    if include_main and hasattr(ctx.file, "main") and ctx.file.main:
        args.append("\"$(rlocation {})\"".format(to_rlocation_path(ctx, ctx.file.main)))

    return args

def _assemble_shared(ctx):
    """Resolve the py toolchain, virtual deps, imports depset — then run
    the shared venv-assembly helper.
    """
    py_toolchain = _py_semantics.resolve_toolchain(ctx)
    virtual_resolution = _py_library.resolve_virtuals(ctx)
    imports_depset = _py_library.make_imports_depset(
        ctx,
        extra_imports_depsets = virtual_resolution.imports,
    )
    wheels_depset = _py_library.make_wheels_depset(ctx)

    default_env = {
        "BAZEL_TARGET": str(ctx.label).lstrip("@"),
        "BAZEL_WORKSPACE": ctx.workspace_name,
        "BAZEL_TARGET_NAME": ctx.attr.name,
    }

    safe_name = ctx.attr.name.replace("/", "_")

    # `venv_dir_basename` lets callers pin the venv's on-disk name
    # regardless of target name — handy for pinning IDE / test fixture
    # paths that hardcode a specific venv dir. Defaults to `.<name>/`
    # (with `_venv` appended when assemble_venv's `venv_name` param
    # isn't set explicitly; see venv.bzl for the default there).
    venv_basename = ctx.attr.venv_dir_basename or ".{}".format(safe_name)
    venv = assemble_venv(
        ctx,
        safe_name = safe_name,
        py_toolchain = py_toolchain,
        imports_depset = imports_depset,
        package_collisions = ctx.attr.package_collisions,
        include_system_site_packages = ctx.attr.include_system_site_packages,
        include_user_site_packages = ctx.attr.include_user_site_packages,
        default_env = default_env,
        venv_activate_tmpl = ctx.file._venv_activate_tmpl,
        virtualenv_shim_py = ctx.file._virtualenv_shim,
        venv_name = venv_basename,
    )

    srcs_depset = _py_library.make_srcs_depset(ctx)
    runfiles = _py_library.make_merged_runfiles(
        ctx,
        extra_depsets = [
            py_toolchain.files,
            srcs_depset,
        ] + virtual_resolution.srcs + virtual_resolution.runfiles,
        extra_runfiles = venv.all_files,
        extra_runfiles_depsets = [
            ctx.attr._runfiles_lib[DefaultInfo].default_runfiles,
        ],
    )

    return struct(
        py_toolchain = py_toolchain,
        venv = venv,
        runfiles = runfiles,
        imports_depset = imports_depset,
        wheels_depset = wheels_depset,
        srcs_depset = srcs_depset,
    )

def _py_venv_rule_impl(ctx):
    """A virtualenv target whose own executable activates the venv and
    exec's the interpreter — a `bazel run :name`-able venv."""

    shared = _assemble_shared(ctx)

    ctx.actions.expand_template(
        template = ctx.file._run_tmpl,
        output = ctx.outputs.executable,
        substitutions = {
            "{{BASH_RLOCATION_FN}}": BASH_RLOCATION_FUNCTION.strip(),
            "{{INTERPRETER_FLAGS}}": " ".join(_interpreter_flags(ctx)),
            "{{ARG_VENV_PYTHON}}": to_rlocation_path(ctx, shared.venv.bin_python),
            "{{DEBUG}}": str(ctx.attr.debug).lower(),
        },
        is_executable = True,
    )

    passed_env = dict(ctx.attr.env)
    for k, v in passed_env.items():
        passed_env[k] = expand_variables(
            ctx,
            expand_locations(ctx, v, ctx.attr.data),
            attribute_name = "env",
        )

    return [
        DefaultInfo(
            files = depset([ctx.outputs.executable]),
            executable = ctx.outputs.executable,
            runfiles = shared.runfiles,
        ),
        # Does not provide PyInfo because venvs are terminal artifacts —
        # a py_binary consumer would see this as "the binary to run",
        # not "a source of imports".
        VirtualenvInfo(
            bin_python = shared.venv.bin_python,
            venv_name = shared.venv.venv_name,
            imports = shared.imports_depset,
            wheels = shared.wheels_depset,
            transitive_sources = shared.srcs_depset,
        ),
        # Forwarded to the sibling py_binary/py_test consumer (created
        # by `expose_venv = True`) so env vars declared on the venv
        # apply to the binary using it. The binary's own `env` wins on
        # key conflicts; see py_binary.bzl.
        RunEnvironmentInfo(
            environment = passed_env,
            inherited_environment = ctx.attr.env_inherit,
        ),
        # `bazel coverage` walks the binary's `external_venv` attr to
        # pick this up — the venv carries the test's `srcs` and
        # first-party `deps`, so this is where instrumentation belongs.
        coverage_common.instrumented_files_info(
            ctx,
            source_attributes = ["srcs"],
            dependency_attributes = ["deps"],
            extensions = ["py"],
        ),
    ]

_attrs = dict({
    "venv": attr.string(
        doc = """The name of a configured virtualenv within which to resolve dependencies.

Default value.
May be overridden with the --@pip//venv=<> CLI flag.
Only works with the experimental Aspect pip machinery.
""",
    ),
    "python_version": attr.string(
        doc = """Whether to build this target and its transitive deps for a specific python version.""",
    ),
    "package_collisions": attr.string(
        doc = """What to do when two wheels both claim the same top-level or console-script name.

See `py_binary`'s attribute of the same name for full semantics — the
two rules share the underlying collision detector.

* "error": Fail analysis.
* "warning" (default): Print a warning; first-seen wins.
* "ignore": First-seen wins silently.
""",
        default = "warning",
        values = ["error", "warning", "ignore"],
    ),
    "interpreter_options": attr.string_list(
        doc = "Additional options to pass to the Python interpreter.",
        default = [],
    ),
    "include_system_site_packages": attr.bool(
        default = False,
        doc = """`pyvenv.cfg` feature flag for the `include-system-site-packages` key.""",
    ),
    "include_user_site_packages": attr.bool(
        default = False,
        doc = """`pyvenv.cfg` feature flag for the `aspect-include-user-site-packages` extension key.""",
    ),
    "debug": attr.bool(
        default = False,
    ),
    "env": attr.string_dict(
        doc = """Environment variables to set when running the venv (and the
sibling py_binary/py_test consumer when `expose_venv = True` is used).
Binary-level `env` wins on key conflicts.""",
        default = {},
    ),
    "env_inherit": attr.string_list(
        doc = """Names of environment variables to pass through from the invoking
environment. Forwarded to the sibling py_binary/py_test consumer
(when `expose_venv = True` is used) alongside `env`.""",
        default = [],
    ),
    "venv_dir_basename": attr.string(
        doc = """Override the generated venv's directory basename.

Defaults to `.<target_name>/`. Overrideable when test fixtures or
IDE configs hardcode a specific path independent of the target name.
""",
    ),
    # Required for py_version attribute
    "_allowlist_function_transition": attr.label(
        default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
    ),
    "_run_tmpl": attr.label(
        allow_single_file = True,
        default = "//py/private/py_venv:venv.tmpl.sh",
    ),
    "_runfiles_lib": attr.label(
        default = "@bazel_tools//tools/bash/runfiles",
    ),
    # Read by py_semantics — freethreaded interpreters expect site-packages
    # at `lib/python<M>.<m>t/site-packages/`, not the default `.../python<M>.<m>/`.
    "_freethreaded_flag": attr.label(
        default = "//py/private/interpreter:freethreaded",
    ),
    # Shared with py_binary via the venv-assembly helper.
    "_venv_activate_tmpl": attr.label(
        allow_single_file = True,
        default = "//py/private:venv_activate.tmpl.sh",
    ),
    "_virtualenv_shim": attr.label(
        allow_single_file = True,
        default = "//py/private:_virtualenv.py",
    ),
})

_attrs.update(**_py_library.attrs)

_py_venv = rule(
    doc = """Build a Python virtual environment and execute its interpreter.""",
    implementation = _py_venv_rule_impl,
    attrs = _attrs,
    toolchains = [PY_TOOLCHAIN],
    executable = True,
    cfg = python_version_transition,
)

def _wrap_with_debug(rule):
    def helper(**kwargs):
        kwargs["debug"] = select({
            Label(":debug_venv_setting"): True,
            "//conditions:default": False,
        })
        return rule(**kwargs)

    return helper

def _py_venv_binary_impl(ctx):
    """A virtualenv-based binary/test that runs a specific Python file."""
    shared = _assemble_shared(ctx)

    ctx.actions.expand_template(
        template = ctx.file._run_tmpl,
        output = ctx.outputs.executable,
        substitutions = {
            "{{BASH_RLOCATION_FN}}": BASH_RLOCATION_FUNCTION.strip(),
            "{{INTERPRETER_FLAGS}}": " ".join(_interpreter_flags(ctx, include_main = True)),
            "{{ARG_VENV_PYTHON}}": to_rlocation_path(ctx, shared.venv.bin_python),
            "{{DEBUG}}": str(ctx.attr.debug).lower(),
        },
        is_executable = True,
    )

    passed_env = dict(ctx.attr.env)
    for k, v in passed_env.items():
        passed_env[k] = expand_variables(
            ctx,
            expand_locations(ctx, v, ctx.attr.data),
            attribute_name = "env",
        )

    return [
        DefaultInfo(
            files = depset([ctx.outputs.executable]),
            executable = ctx.outputs.executable,
            runfiles = shared.runfiles,
        ),
        RunEnvironmentInfo(
            environment = passed_env,
            inherited_environment = getattr(ctx.attr, "env_inherit", []),
        ),
    ]

_binary_attrs = dict({
    "main": attr.label(
        doc = "Script to execute with the Python interpreter.",
        allow_single_file = True,
        mandatory = True,
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
    # see https://github.com/aspect-build/rules_py/pull/520#pullrequestreview-25790761972
    "_lcov_merger": attr.label(
        default = configuration_field(fragment = "coverage", name = "output_generator"),
        executable = True,
        cfg = "exec",
    ),
})

_py_venv_binary = rule(
    doc = """Run a Python program under Bazel using a virtualenv.""",
    implementation = _py_venv_binary_impl,
    attrs = _attrs | _binary_attrs,
    toolchains = [PY_TOOLCHAIN],
    executable = True,
    cfg = python_version_transition,
)

_py_venv_test = rule(
    doc = """Run a Python program under Bazel using a virtualenv.""",
    implementation = _py_venv_binary_impl,
    attrs = _attrs | _binary_attrs | _test_attrs,
    toolchains = [PY_TOOLCHAIN],
    test = True,
    cfg = python_version_transition,
)

py_venv = _wrap_with_debug(_py_venv)
py_venv_binary = _wrap_with_debug(_py_venv_binary)
py_venv_test = _wrap_with_debug(_py_venv_test)

# Attrs that belong on the generated `py_venv` when `py_binary_with_venv`
# splits a `py_binary` / `py_test` call. Everything else belongs on the
# launcher rule. `interpreter_options` is launcher-only — the launcher
# uses it for `python <flags> main.py`; the venv's interactive REPL
# (`bazel run :name.venv`) doesn't need the binary's flags.
_VENV_ONLY_ATTRS = [
    "deps",
    "imports",
    "resolutions",
    "virtual_deps",
    "package_collisions",
    "include_system_site_packages",
    "include_user_site_packages",
    "venv",
    "python_version",
]

def _split_kwargs_for_venv(kwargs):
    """Pop venv-only kwargs off `kwargs` and return a dict to pass to
    `py_venv`. `kwargs` is mutated — popped attrs no longer reach the
    launcher rule.
    """
    venv_kwargs = {}
    for name in _VENV_ONLY_ATTRS:
        if name in kwargs:
            venv_kwargs[name] = kwargs.pop(name)
    return venv_kwargs

def py_binary_with_venv(py_rule, name, main, srcs = [], deps = [], data = None, imports = [], tags = None, testonly = None, visibility = None, isolated = True, expose_venv = False, **kwargs):
    """Split `py_rule(name, ...)` into a sibling py_venv target + a
    `py_rule` call routed at it via the internal `external_venv` rule
    attribute. Called for every `py_binary` / `py_test` macro invocation.

    `expose_venv = True` emits a public `:{name}.venv` py_venv:
    runnable (`bazel run :{name}.venv` drops into the hermetic
    interpreter) and pairable with `py_venv_link` for IDE integration.
    The venv inherits the binary's visibility.

    All venv-shaping attrs (`deps`, `imports`, `package_collisions`,
    `include_*_site_packages`, `interpreter_options`) land on the
    sibling venv.
    """
    venv_kwargs = _split_kwargs_for_venv(kwargs)
    venv_kwargs["srcs"] = srcs
    venv_kwargs["deps"] = deps
    venv_kwargs["imports"] = imports

    # Target names can contain `/` (Bazel allows it), but venv labels
    # and the on-disk venv basename must be slash-free.
    safe_name = name.replace("/", "_")
    if expose_venv:
        venv_label = "{}.venv".format(name)
        venv_visibility = visibility
        venv_tags = None
        venv_basename = None
    else:
        venv_label = "_{}_venv".format(safe_name)
        venv_visibility = ["//visibility:private"]
        venv_tags = ["manual"]
        venv_basename = ".{}.venv".format(safe_name)

    py_venv(
        name = venv_label,
        venv_dir_basename = venv_basename,
        testonly = testonly,
        visibility = venv_visibility,
        tags = venv_tags,
        **venv_kwargs
    )

    py_rule(
        name = name,
        main = main,
        data = data,
        tags = tags,
        testonly = testonly,
        visibility = visibility,
        external_venv = ":" + venv_label,
        isolated = isolated,
        **kwargs
    )

def py_venv_link(venv_name = None, srcs = [], **kwargs):
    """Build a Python virtual environment and produce a script to link it into the build directory."""

    # Note that the binary is already wrapped with debug
    link_script = str(Label("//py/private/py_venv:link.py"))
    kwargs["debug"] = select({
        Label(":debug_venv_setting"): True,
        "//conditions:default": False,
    })
    py_venv_binary(
        args = [] + (["--name=" + venv_name] if venv_name else []),
        main = link_script,
        srcs = srcs + [link_script],
        **kwargs
    )
