"""Implementation for the `py_venv` rule + `py_venv_link` and `py_binary_with_venv` macros.

- `py_venv` — a rule that builds a Python virtualenv and produces an
  executable that activates it and exec's `bin/python`. Emits
  `VirtualenvInfo` consumed by `py_binary_with_venv` (the
  `expose_venv = True` codepath). `bazel run :name` on a py_venv drops
  into the hermetic interpreter with the venv activated — useful for
  interactive Python sessions.

- `py_binary_with_venv` — shared helper invoked by `py_binary` and
  `py_test`. Ordinary targets remain one direct configured target that
  owns a private runtime venv. When `expose_venv = True`, the helper
  instead splits the call into a sibling `:<name>.venv` `py_venv` +
  a launcher rule that consumes it via the internal `venv` attribute.
  `bazel run :<name>.venv` drops into the interpreter.

- `py_venv_link` — opt-in macro that emits a runnable target whose
  `bazel run` materialises a workspace-local symlink to an existing
  `py_venv`'s tree. Pair with `py_binary(expose_venv = True)` to hand
  your IDE a stable `.venv` symlink to point at.

Shared venv-assembly logic lives in
`//py/private/py_venv:venv.bzl::assemble_venv`. See that file's header for the
layout details.
"""

load("@bazel_lib//lib:expand_make_vars.bzl", "expand_locations", "expand_variables")
load("@bazel_lib//lib:paths.bzl", "BASH_RLOCATION_FUNCTION", "to_rlocation_path")
load("@hermetic_launcher//launcher:lib.bzl", "launcher")
load("//py/private:providers.bzl", "PyVenvLayoutInfo")
load("//py/private:py_library.bzl", _py_library = "py_library_utils")
load("//py/private:py_semantics.bzl", _py_semantics = "semantics")
load("//py/private:transitions.bzl", "python_version_transition")
load("//py/private/toolchain:types.bzl", "EXEC_TOOLS_TOOLCHAIN", "PY_TOOLCHAIN")
load(":py_venv_exec.bzl", _py_venv_link_exec = "py_venv_link_exec")
load(":types.bzl", "VirtualenvInfo")
load(":venv.bzl", "assemble_venv")

def _interpreter_flags(ctx, include_main = False):
    py_toolchain = _py_semantics.resolve_toolchain(ctx)
    args = py_toolchain.flags + ctx.attr.interpreter_options

    # py_venv strips `-I` so the interpreter picks up PYTHONPATH and
    # script dir — useful when users `bazel run` the venv for an
    # interactive python session and want their shell's env to apply.
    # The per-binary py_binary launcher keeps `-I` (see py_venv_exec.bzl).
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
    is_windows = ctx.target_platform_has_constraint(
        ctx.attr._windows_constraint[platform_common.ConstraintValueInfo],
    )

    venv = assemble_venv(
        ctx,
        safe_name = safe_name,
        py_toolchain = py_toolchain,
        imports_depset = imports_depset,
        package_collisions = ctx.attr.package_collisions,
        include_system_site_packages = ctx.attr.include_system_site_packages,
        include_user_site_packages = ctx.attr.include_user_site_packages,
        default_env = default_env,
        materialize_wheel_tree_aliases = True,
        launcher_bootstrap_py = ctx.file._launcher_bootstrap,
        python_wrapper_tmpl = ctx.file._python_wrapper_tmpl,
        standalone_interpreter = not is_windows,
        runfiles_imports_py = ctx.file._runfiles_imports,
        venv_startup_py = ctx.file._venv_startup,
        venv_activate_tmpl = ctx.file._venv_activate_tmpl,
        virtualenv_shim_py = ctx.file._virtualenv_shim,
        site_merge_script_py = ctx.file._site_merge_script,
        venv_name = ".{}".format(safe_name),
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

    if "VIRTUAL_ENV" in ctx.attr.env:
        fail("py_venv {}: `VIRTUAL_ENV` is set by the rule and cannot be overridden via `env`.".format(ctx.label))

    passed_env = dict(ctx.attr.env)
    for k, v in passed_env.items():
        passed_env[k] = expand_variables(
            ctx,
            expand_locations(ctx, v, ctx.attr.data),
            attribute_name = "env",
        )

    # `VIRTUAL_ENV` as the venv root's rootpath. `venv.tmpl.sh`
    # overrides with its own absolute value when invoked directly.
    # `rsplit` drops the trailing `bin/python` to leave the venv root.
    passed_env["VIRTUAL_ENV"] = shared.venv.bin_python.short_path.rsplit("/", 2)[0]

    return [
        DefaultInfo(
            files = depset([ctx.outputs.executable]),
            executable = ctx.outputs.executable,
            runfiles = shared.runfiles,
        ),
        PyVenvLayoutInfo(
            dependency_files = depset(shared.venv.dependency_files),
            wheel_aliases = depset(shared.venv.wheel_aliases),
            wheel_links = depset(shared.venv.wheel_links),
        ),
        # Does not provide PyInfo because venvs are terminal artifacts —
        # a py_binary consumer would see this as "the binary to run",
        # not "a source of imports".
        VirtualenvInfo(
            bin_python = shared.venv.bin_python,
            runtime_python = shared.venv.runtime_python,
            venv_name = shared.venv.venv_name,
            imports = shared.imports_depset,
            wheels = shared.wheels_depset,
            transitive_sources = shared.srcs_depset,
        ),
        # Forwarded to the sibling py_binary/py_test consumer (created
        # by `expose_venv = True`) so env vars declared on the venv
        # apply to the binary using it. The binary's own `env` wins on
        # key conflicts; see py_venv_exec.bzl.
        RunEnvironmentInfo(
            environment = passed_env,
            inherited_environment = ctx.attr.env_inherit,
        ),
        # `bazel coverage` walks the binary's `venv` attr to
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
    "dep_group": attr.string(
        default = "",
        doc = """The name of a configured dependency group within which to resolve dependencies.

May be overridden with the --@pip//dep_group=<> CLI flag.
Only works with the Aspect rules_py uv machinery.
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
    # Required for py_version attribute
    "_allowlist_function_transition": attr.label(
        default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
    ),
    "_run_tmpl": attr.label(
        allow_single_file = True,
        default = ":venv.tmpl.sh",
    ),
    "_runfiles_lib": attr.label(
        default = "@bazel_tools//tools/bash/runfiles",
    ),
    # Read by py_semantics — freethreaded interpreters expect site-packages
    # at `lib/python<M>.<m>t/site-packages/`, not the default `.../python<M>.<m>/`.
    "_freethreaded_flag": attr.label(
        default = "//py/private/interpreter:freethreaded",
    ),
    "_launcher_bootstrap": attr.label(
        allow_single_file = True,
        default = ":launcher_bootstrap.py",
    ),
    "_python_wrapper_tmpl": attr.label(
        allow_single_file = True,
        default = ":python_wrapper.sh.tmpl",
    ),
    "_runfiles_imports": attr.label(
        allow_single_file = True,
        default = ":runfiles_imports.py",
    ),
    "_venv_startup": attr.label(
        allow_single_file = True,
        default = ":venv_startup.py",
    ),
    # Shared with py_binary via the venv-assembly helper.
    "_venv_activate_tmpl": attr.label(
        allow_single_file = True,
        default = ":venv_activate.tmpl.sh",
    ),
    "_virtualenv_shim": attr.label(
        allow_single_file = True,
        default = ":_virtualenv.py",
    ),
    "_windows_constraint": attr.label(
        default = "@platforms//os:windows",
    ),
    # Tool for physically merging regular-package subtrees across wheels.
    "_site_merge_script": attr.label(
        allow_single_file = True,
        default = "//py/tools/site_merge:site_merge.py",
    ),
})

_attrs.update(**_py_library.attrs)

_py_venv = rule(
    doc = """Build a Python virtual environment and execute its interpreter.""",
    implementation = _py_venv_rule_impl,
    attrs = _attrs,
    toolchains = [
        PY_TOOLCHAIN,
        launcher.finalizer_toolchain_type,
        launcher.template_toolchain_type,
        # Optional: only consulted when a regular package spans wheels and
        # assemble_venv needs an exec-config interpreter to run the
        # site_merge action. Optional so venvs keep analyzing in setups that
        # never registered rules_py's exec-tools toolchain.
        config_common.toolchain_type(EXEC_TOOLS_TOOLCHAIN, mandatory = False),
    ],
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

# Attrs that the macro routes to the generated `py_venv`. Two flavors:
# venv-only (popped from kwargs, the launcher never sees them) and
# shared (copied into venv kwargs but kept in kwargs so they also reach
# the launcher rule).
_VENV_ONLY_ATTRS = [
    "deps",
    "imports",
    "resolutions",
    "virtual_deps",
    "package_collisions",
    "include_system_site_packages",
    "include_user_site_packages",
    "env",
    "env_inherit",
]
_SHARED_ATTRS = [
    # The launcher resolves configurable srcs/main/data in its own
    # configuration, so it must match the sibling venv.
    "python_version",
    "dep_group",
    # Launcher constructs `python <flags> main.py`; venv forwards them
    # to its REPL so `bazel run :name.venv` matches the binary's flags.
    "interpreter_options",
]

def _split_kwargs_for_venv(kwargs):
    """Build the kwargs dict to pass to `py_venv`. `kwargs` is mutated:
    venv-only attrs are popped; shared attrs are copied (left in
    `kwargs` so they also reach the launcher).
    """
    venv_kwargs = {}
    for name in _VENV_ONLY_ATTRS:
        if name in kwargs:
            venv_kwargs[name] = kwargs.pop(name)
    for name in _SHARED_ATTRS:
        if name in kwargs:
            venv_kwargs[name] = kwargs[name]
    return venv_kwargs

def py_binary_with_venv(py_rule, direct_rule, name, main, srcs = [], deps = [], data = [], imports = [], tags = None, testonly = None, visibility = None, isolated = True, expose_venv = None, expose_venv_link = False, **kwargs):
    """Create a direct Python target, or a sibling physical venv plus
    launcher when `expose_venv = True`.

    `expose_venv = True` emits a public `:{name}.venv` py_venv:
    runnable (`bazel run :{name}.venv` drops into the hermetic
    interpreter) and pairable with `py_venv_link` for IDE integration.
    The venv inherits the binary's visibility. Default `None` (unset);
    treated as `False` unless `expose_venv_link = True` promotes it.

    `expose_venv_link = True` additionally emits a public
    `:{name}.venv_link` py_venv_link. `bazel run :{name}.venv_link`
    materialises a workspace-local symlink at the venv's tree under
    `bazel-bin`, suitable for pointing an IDE at. Implies
    `expose_venv = True` — the link target needs a public venv to point
    at. Passing `expose_venv = False, expose_venv_link = True`
    explicitly is contradictory and fails.

    In the exposed form, all venv-shaping attrs (`deps`, `imports`,
    `package_collisions`, `include_*_site_packages`,
    `interpreter_options`) land on the sibling venv.
    """
    if expose_venv_link:
        if expose_venv == False:
            fail("py_binary/py_test {!r}: expose_venv_link = True requires a public venv to link, but expose_venv = False was passed explicitly. Drop expose_venv = False, or set expose_venv_link = False.".format(name))
        expose_venv = True
    else:
        expose_venv = bool(expose_venv)

    if not expose_venv:
        direct_rule(
            name = name,
            main = main,
            srcs = srcs,
            deps = deps,
            data = data,
            imports = imports,
            tags = tags,
            testonly = testonly,
            visibility = visibility,
            isolated = isolated,
            **kwargs
        )
        return

    venv_kwargs = _split_kwargs_for_venv(kwargs)
    venv_kwargs["srcs"] = srcs
    venv_kwargs["deps"] = deps
    venv_kwargs["imports"] = imports
    venv_kwargs["data"] = data

    venv_label = "{}.venv".format(name)
    py_venv(
        name = venv_label,
        testonly = testonly,
        visibility = visibility,
        tags = tags,
        **venv_kwargs
    )

    if expose_venv_link:
        py_venv_link(
            name = "{}.venv_link".format(name),
            venv = ":" + venv_label,
            tags = tags,
            testonly = testonly,
            visibility = visibility,
        )

    py_rule(
        name = name,
        main = main,
        srcs = srcs,
        # `data` lands on both targets: the venv merges it into the
        # runfiles every consumer inherits, while the launcher needs it
        # directly so `args` / `env` `$(location :data_file)` expansion
        # and the coverage walk can resolve the label (srcs are kept on
        # the launcher for the same reason).
        data = data,
        tags = tags,
        testonly = testonly,
        visibility = visibility,
        venv = ":" + venv_label,
        isolated = isolated,
        **kwargs
    )

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
        **kwargs: Forwarded to the internal launcher rule.
    """
    link_script = str(Label(":link.py"))
    _py_venv_link_exec(
        name = name,
        main = link_script,
        srcs = [link_script],
        args = [] + (["--name=" + link_name] if link_name else []),
        venv = venv,
        isolated = False,
        **kwargs
    )
