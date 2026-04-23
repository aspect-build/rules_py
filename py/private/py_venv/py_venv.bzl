"""Implementation for the `py_venv` rule + `py_venv_link` and `py_binary_with_venv` macros.

- `py_venv` — a rule that builds a Python virtualenv and produces an
  executable that activates it and exec's `bin/python`. Emits
  `VirtualenvInfo` so other targets consume it via `external_venv=`.
  `bazel run :name` on a py_venv drops into the hermetic interpreter
  with the venv activated — useful for interactive Python sessions.

- `py_binary_with_venv` — shared helper invoked by
  `py_binary(expose_venv = True, ...)` / `py_test(expose_venv = True, ...)`.
  Splits the call into a sibling `:<name>.venv` `py_venv` + a
  `py_binary` / `py_test` rule consuming it via `external_venv`.
  First-class sibling: other targets can share the `.venv` via
  `external_venv`, and `bazel run :<name>.venv` drops into the
  interpreter.

- `py_venv_link` — opt-in macro that emits a runnable target whose
  `bazel run` materialises a workspace-local symlink to an existing
  `py_venv`'s tree. Pair with `py_binary(expose_venv = True)` to hand
  your IDE a stable `.venv` symlink to point at.

- `py_venv_binary` / `py_venv_test` — **removed in v2.0.0.** Left
  behind as `fail()`-ing stubs that direct callers to
  `py_binary` / `py_test` with `expose_venv = True, isolated = False`.

Shared venv-assembly logic lives in
`//py/private:venv.bzl::assemble_venv`. See that file's header for the
layout details.
"""

load("@bazel_lib//lib:expand_make_vars.bzl", "expand_locations", "expand_variables")
load("@bazel_lib//lib:paths.bzl", "BASH_RLOCATION_FUNCTION", "to_rlocation_path")
load("//py/private:py_binary.bzl", "py_binary")
load("//py/private:py_library.bzl", _py_library = "py_library_utils")
load("//py/private:py_semantics.bzl", _py_semantics = "semantics")
load("//py/private:transitions.bzl", "python_version_transition")
load("//py/private:venv.bzl", "assemble_venv")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN")
load(":types.bzl", "VirtualenvInfo")

def _interpreter_flags(ctx):
    py_toolchain = _py_semantics.resolve_toolchain(ctx)
    args = py_toolchain.flags + ctx.attr.interpreter_options

    # py_venv strips `-I` so the interpreter picks up PYTHONPATH and
    # script dir — useful when users `bazel run` the venv for an
    # interactive python session and want their shell's env to apply.
    # The per-binary py_binary launcher keeps `-I` (see py_binary.bzl).
    args = [it for it in args if it not in ["-I"]]

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
            files = depset([ctx.outputs.executable] + shared.venv.all_files),
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
        ),
        # Forwarded to py_binary(external_venv = :this_venv) consumers
        # so env vars declared on the venv apply to binaries using it.
        # The binary's own `env` wins on key conflicts; see py_binary.bzl.
        RunEnvironmentInfo(
            environment = passed_env,
            inherited_environment = ctx.attr.env_inherit,
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
    "mode": attr.string(
        doc = """Legacy attr, no longer honored.

Historically selected between `static-pth` and `static-symlink` assembly
strategies. The current venv assembly is always per-top-level-symlink
for wheels with `PyWheelsInfo` metadata and `.pth` for everything else
— there's no mode to choose. Attribute retained for API compatibility.
""",
        default = "static-symlink",
        values = ["static-pth", "static-symlink"],
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
        doc = """Environment variables to set when running the venv (and any
`py_binary(external_venv = ...)` consumer). Binary-level `env` wins on
key conflicts.""",
        default = {},
    ),
    "env_inherit": attr.string_list(
        doc = """Names of environment variables to pass through from the invoking
environment. Forwarded to `py_binary(external_venv = ...)` consumers
alongside `env`.""",
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
        default = "//py/private/py_venv:entrypoint.tmpl.sh",
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

py_venv = _wrap_with_debug(_py_venv)

# Attrs that belong on the generated `py_venv` when `py_binary_with_venv`
# splits a `py_binary(expose_venv = True, ...)` call into (venv, binary)
# targets. Everything else belongs on the binary/test target. Some
# attrs (`python_version`, `venv`) need to land on BOTH so the
# python_version_transition picks the same config for both —
# otherwise the binary's `data` resolves wheels under a different uv
# VENV_FLAG / python version than the venv was built for, and
# `select()`-driven hub picks diverge.
_VENV_ONLY_ATTRS = [
    "deps",
    "imports",
    "resolutions",
    "virtual_deps",
    "package_collisions",
    "include_system_site_packages",
    "include_user_site_packages",
    "interpreter_options",
]
_SHARED_TRANSITION_ATTRS = [
    "python_version",
    "venv",  # uv's pip-extension config-transition attr (string)
]

def _split_kwargs_for_venv(kwargs):
    """Pop venv-only kwargs off the dict and copy the shared-transition
    ones. Returns the dict to pass to py_venv. `kwargs` is mutated:
    venv-only attrs are popped; shared-transition attrs stay so they
    also reach the py_binary/py_test call.
    """
    venv_kwargs = {}
    for name in _VENV_ONLY_ATTRS:
        if name in kwargs:
            venv_kwargs[name] = kwargs.pop(name)
    for name in _SHARED_TRANSITION_ATTRS:
        if name in kwargs:
            venv_kwargs[name] = kwargs[name]
    return venv_kwargs

def py_binary_with_venv(py_rule, name, main, srcs = None, deps = None, data = None, imports = None, tags = None, testonly = None, visibility = None, venv_dir_basename = None, isolated = True, **kwargs):
    """Split `py_rule(name, ...)` into a `{name}.venv` py_venv target +
    a `py_rule` call with `external_venv = :{name}.venv`.

    Called by `py_binary` / `py_test` when `expose_venv = True`. The
    emitted `:{name}.venv` is a first-class public target: shareable
    via `external_venv` from other `py_binary` / `py_test` callsites,
    and `bazel run :{name}.venv`-able to drop into the hermetic
    interpreter for an interactive session.

    All venv-shaping attrs (`deps`, `imports`, `package_collisions`,
    `include_*_site_packages`, `interpreter_options`) land on the
    `.venv` target. The rule's own dep closure is empty by
    construction, so the analysis-time subset-coverage check in
    py_binary's `_check_venv_coverage` is trivially satisfied.
    """
    venv_kwargs = _split_kwargs_for_venv(kwargs)
    if deps != None:
        venv_kwargs["deps"] = deps
    if imports != None:
        venv_kwargs["imports"] = imports

    venv_label = "{}.venv".format(name)

    py_venv(
        name = venv_label,
        venv_dir_basename = venv_dir_basename,
        testonly = testonly,
        visibility = visibility,
        **venv_kwargs
    )

    py_rule(
        name = name,
        main = main,
        srcs = srcs or [],
        data = data,
        tags = tags,
        testonly = testonly,
        visibility = visibility,
        external_venv = ":" + venv_label,
        isolated = isolated,
        **kwargs
    )

_REMOVED_MIGRATION = """\
{rule}(name = "{name}") was removed in rules_py v2.0.0.

Replacement: {new_rule} from @aspect_rules_py//py:defs.bzl, called with
the two attributes that {rule} used to inject for you:

    {new_rule}(
        name = "{name}",
        # ... existing attrs ...
        expose_venv = True,
        isolated = False,
    )

`expose_venv = True` splits the target into a sibling `:{name}.venv`
py_venv (shareable via `external_venv`, runnable to drop into the
interpreter) and a {new_rule} consuming it.
`isolated = False` drops Python's `-I` flag so PYTHONPATH / script-dir
auto-add / user-site behave the way they did under {rule}.

If you don't need those specific semantics, plain `{new_rule}(...)`
with no extra attrs is the common case — analysis-time venv assembly
is built into the default shape.
"""

def py_venv_binary(name, **_kwargs):
    """Removed in rules_py v2.0.0. Calling this macro fails with a migration message pointing at py_binary + expose_venv."""
    fail(_REMOVED_MIGRATION.format(
        rule = "py_venv_binary",
        new_rule = "py_binary",
        name = name,
    ))

def py_venv_test(name, **_kwargs):
    """Removed in rules_py v2.0.0. Calling this macro fails with a migration message pointing at py_test + expose_venv."""
    fail(_REMOVED_MIGRATION.format(
        rule = "py_venv_test",
        new_rule = "py_test",
        name = name,
    ))

def py_venv_link(name, venv, link_name = None, **kwargs):
    """Emit a runnable target that materialises `venv` into the workspace.

    `bazel run :<name>` creates a symlink in `$BUILD_WORKING_DIRECTORY`
    (typically the workspace root) that points at `venv`'s materialised
    venv tree in bazel-bin, so IDEs / LSPs can resolve interpreter and
    site-packages via a stable workspace-local path.

    Args:
        name: Runnable target name. `bazel run :<name>` materialises
            the symlink; pick something like `<something>.venv` by
            convention so `python.defaultInterpreterPath` readers
            recognise it, but any label works.
        venv: Label of a `py_venv` target to link. Typically the
            `:<binary_name>.venv` target auto-emitted by
            `py_binary(expose_venv = True, ...)`, or a standalone
            `py_venv` shared across many binaries.
        link_name: Workspace-relative basename for the created
            symlink. Defaults to a safely-escaped version of the
            target's package + venv name.
        **kwargs: Forwarded to the underlying `py_binary`.
    """
    link_script = str(Label("//py/private/py_venv:link.py"))
    py_binary(
        name = name,
        main = link_script,
        srcs = [link_script],
        args = [] + (["--name=" + link_name] if link_name else []),
        external_venv = venv,
        isolated = False,
        **kwargs
    )
