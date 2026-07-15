"""Implementation for the ``py_venv`` rule + ``py_venv_link`` and
``py_binary_with_venv`` macros.

- ``py_venv`` — builds a Python virtualenv and produces an executable
  that activates it and exec's ``bin/python``.  Emits ``VirtualenvInfo``
  consumed by ``py_binary_with_venv`` (the ``expose_venv = True``
  codepath).  ``bazel run :name`` drops into the hermetic interpreter
  with the venv activated.

- ``py_binary_with_venv`` — shared helper invoked by
  ``py_binary(expose_venv = True, ...)`` /
  ``py_test(expose_venv = True, ...)``.  Splits the call into a sibling
  ``:<name>.venv`` ``py_venv`` + a launcher rule that consumes it.

- ``py_venv_link`` — opt-in macro that emits a runnable target whose
  ``bazel run`` links the runfiles tree into the workspace and prints
  the venv path for IDE integration.

Shared venv-assembly logic lives in
``//py/private/py_venv:assemble_venv.bzl::assemble_venv``.
"""

load("@bazel_lib//lib:expand_make_vars.bzl", "expand_locations", "expand_variables")
load("@bazel_lib//lib:paths.bzl", "BASH_RLOCATION_FUNCTION", "to_rlocation_path")
load("//py/private:py_library.bzl", _py_library = "py_library_utils")
load("//py/private:py_semantics.bzl", _py_semantics = "semantics")
load("//py/private:transitions.bzl", "python_transition")
load("//py/private/toolchain:types.bzl", "EXEC_TOOLS_TOOLCHAIN", "PY_TOOLCHAIN")
load(":assemble_venv.bzl", "assemble_venv")
load(":py_venv_exec.bzl", _py_venv_exec = "py_venv_exec")
load(":types.bzl", "VirtualenvInfo", "venv_root")

_VENV_ONLY_ATTRS = [
    "resolutions",
    "virtual_deps",
    "package_collisions",
    "include_system_site_packages",
    "include_user_site_packages",
    "python_version",
    "dep_group",
]

_SHARED_ATTRS = [
    "interpreter_options",
    "env",
    "env_inherit",
]

def _interpreter_flags(ctx):
    """Build the interpreter flag list for the venv's own REPL.

    ``-I`` is stripped from the **semantics base** so the interactive
    session picks up PYTHONPATH and the script directory.  User
    ``interpreter_options`` are appended verbatim — an explicit ``-I``
    survives.
    """
    base = [f for f in _py_semantics.interpreter_flags if f != "-I"]
    return base + list(ctx.attr.interpreter_options)

def _default_env(ctx):
    """Build the Bazel-contextual env vars injected into ``activate``."""
    return {
        "BAZEL_TARGET": str(ctx.label).lstrip("@"),
        "BAZEL_WORKSPACE": ctx.workspace_name,
        "BAZEL_TARGET_NAME": ctx.attr.name,
    }

def _expand_env_vars(ctx, env):
    """Expand ``$(location)`` and make-vars in every value of *env*."""
    result = dict(env)
    for k, v in result.items():
        result[k] = expand_variables(
            ctx,
            expand_locations(ctx, v, ctx.attr.data),
            attribute_name = "env",
        )
    return result

def _expand_launcher(ctx, shared):
    """Expand the venv launcher template (``venv.tmpl.sh``)."""
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

def _build_run_env(ctx, shared):
    """Construct the ``RunEnvironmentInfo.environment`` dict.

    Fails if the user set ``VIRTUAL_ENV`` explicitly.  The value is a
    runfiles-relative rootpath; ``venv.tmpl.sh`` overrides it with the
    absolute rlocation-resolved path at runtime.
    """
    if "VIRTUAL_ENV" in ctx.attr.env:
        fail("py_venv {}: `VIRTUAL_ENV` is set by the rule and cannot be overridden via `env`.".format(ctx.label))
    env = _expand_env_vars(ctx, ctx.attr.env)
    env["VIRTUAL_ENV"] = venv_root(shared.venv.bin_python)
    return env

def _assemble_shared(ctx):
    """Resolve toolchain, virtual deps, imports — then run ``assemble_venv``."""
    py_toolchain = _py_semantics.resolve_toolchain(ctx)
    virtual_resolution = _py_library.resolve_virtuals(ctx)
    imports_depset = _py_library.make_imports_depset(
        ctx,
        extra_imports_depsets = virtual_resolution.imports,
    )

    safe_name = ctx.attr.name.replace("/", "_")

    venv = assemble_venv(
        ctx,
        safe_name = safe_name,
        py_toolchain = py_toolchain,
        imports_depset = imports_depset,
        is_windows = ctx.target_platform_has_constraint(
            ctx.attr._windows_constraint[platform_common.ConstraintValueInfo],
        ),
        package_collisions = ctx.attr.package_collisions,
        include_system_site_packages = ctx.attr.include_system_site_packages,
        include_user_site_packages = ctx.attr.include_user_site_packages,
        default_env = _default_env(ctx),
        venv_activate_tmpl = ctx.file._venv_activate_tmpl,
        virtualenv_shim_py = ctx.file._virtualenv_shim,
        site_merge_script_py = ctx.file._site_merge_script,
        console_script_tmpl = ctx.file._console_script_tmpl,
        venv_name = ".{}".format(safe_name),
    )

    srcs_depset = _py_library.make_srcs_depset(ctx)
    runfiles = _py_library.make_merged_runfiles(
        ctx,
        extra_depsets = [py_toolchain.files, srcs_depset] + virtual_resolution.srcs + virtual_resolution.runfiles,
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
        srcs_depset = srcs_depset,
    )

def _common_providers(ctx, shared, executable = None):
    """Providers emitted by both the executable and lib variants.

    Deliberately omits ``PyInfo``: a venv is a terminal artifact, not a
    source of imports for downstream ``py_library`` consumers.
    """
    return [
        DefaultInfo(
            files = depset([executable]) if executable != None else None,
            executable = executable,
            runfiles = shared.runfiles,
        ),
        VirtualenvInfo(
            bin_python = shared.venv.bin_python,
            imports = shared.imports_depset,
            transitive_sources = shared.srcs_depset,
            all_files = depset(shared.venv.all_files),
        ),
        coverage_common.instrumented_files_info(
            ctx,
            source_attributes = ["srcs"],
            dependency_attributes = ["deps"],
            extensions = ["py"],
        ),
    ]

def _py_venv_rule_impl(ctx):
    """Executable venv target — ``bazel run :name`` drops into the REPL."""
    shared = _assemble_shared(ctx)
    _expand_launcher(ctx, shared)
    env = _build_run_env(ctx, shared)
    return _common_providers(ctx, shared, executable = ctx.outputs.executable) + [
        RunEnvironmentInfo(
            environment = env,
            inherited_environment = ctx.attr.env_inherit,
        ),
    ]

def _py_venv_lib_rule_impl(ctx):
    """Non-executable venv variant — same providers, no launcher.

    Bazel rejects ``RunEnvironmentInfo`` on non-executable targets, so
    ``py_venv_exec.bzl`` gates its read on ``if RunEnvironmentInfo in
    venv``.
    """
    shared = _assemble_shared(ctx)
    return _common_providers(ctx, shared)

_lib_attrs = dict({
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
        doc = """What to do when metadata-resolved wheel contents collide.

See `py_binary`'s attribute of the same name for full semantics — the two rules
share the underlying collision detector. PEP 420 namespace top-levels merge.
Ordinary directory-valued top-levels and regular-package spans overlay in
the postorder wheel sequence. Other ordinary top-levels, exact namespace
entries, and console scripts select the last distinct claimant; incompatible
namespace prefixes retain the shallower entry. Wheels not represented in
`PyWheelsInfo` remain on the `.pth` fallback. A duplicate dependency edge
does not reinsert a wheel.

* "error": Fail analysis or the physical merge action.
* "warning" (default): Print a warning and apply the permissive behavior above.
* "ignore": Apply the permissive behavior silently.
""",
        default = "warning",
        values = ["error", "warning", "ignore"],
    ),
    "include_system_site_packages": attr.bool(
        default = False,
        doc = """`pyvenv.cfg` feature flag for the `include-system-site-packages` key.""",
    ),
    "include_user_site_packages": attr.bool(
        default = False,
        doc = """`pyvenv.cfg` feature flag for the `aspect-include-user-site-packages` extension key.""",
    ),
    "_allowlist_function_transition": attr.label(
        default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
    ),
    "_runfiles_lib": attr.label(
        default = "@bazel_tools//tools/bash/runfiles",
    ),
    "_freethreaded_flag": attr.label(
        default = "//py/private/interpreter:freethreaded",
    ),
    "_venv_activate_tmpl": attr.label(
        allow_single_file = True,
        default = "templates/venv_activate.tmpl.sh",
    ),
    "_virtualenv_shim": attr.label(
        allow_single_file = True,
        default = "templates/_virtualenv.py",
    ),
    "_console_script_tmpl": attr.label(
        allow_single_file = True,
        default = "templates/console_script.tmpl.sh",
    ),
    "_windows_constraint": attr.label(
        default = "@platforms//os:windows",
    ),
    "_site_merge_script": attr.label(
        allow_single_file = True,
        default = "//py/tools/site_merge:site_merge.py",
    ),
})

_lib_attrs.update(**_py_library.attrs)

_attrs = _lib_attrs | dict({
    "interpreter_options": attr.string_list(
        doc = "Additional options to pass to the Python interpreter.",
        default = [],
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
    "_run_tmpl": attr.label(
        allow_single_file = True,
        default = "templates/venv.tmpl.sh",
    ),
})

_py_venv = rule(
    doc = """Build a Python virtual environment and execute its interpreter.""",
    implementation = _py_venv_rule_impl,
    attrs = _attrs,
    toolchains = [
        PY_TOOLCHAIN,
        config_common.toolchain_type(EXEC_TOOLS_TOOLCHAIN, mandatory = False),
    ],
    executable = True,
    cfg = python_transition,
)

_py_venv_lib = rule(
    implementation = _py_venv_lib_rule_impl,
    attrs = _lib_attrs,
    toolchains = [
        PY_TOOLCHAIN,
        config_common.toolchain_type(EXEC_TOOLS_TOOLCHAIN, mandatory = False),
    ],
    cfg = python_transition,
)

def _wrap_with_debug(rule_fn):
    """Wrap a rule so ``debug`` is driven by the ``:debug_venv_setting`` flag."""

    def helper(**kwargs):
        kwargs["debug"] = select({
            Label(":debug_venv_setting"): True,
            "//conditions:default": False,
        })
        return rule_fn(**kwargs)

    return helper

py_venv = _wrap_with_debug(_py_venv)

def _split_kwargs_for_venv(kwargs, expose_venv):
    """Route attrs between the sibling venv and the launcher.

    ``_VENV_ONLY_ATTRS`` are popped from *kwargs* (the launcher never
    sees them).  ``_SHARED_ATTRS`` are copied into the venv kwargs only
    when the venv is the executable variant (``expose_venv = True``);
    the lib variant does not read them.
    """
    venv_kwargs = {}
    for name in _VENV_ONLY_ATTRS:
        if name in kwargs:
            venv_kwargs[name] = kwargs.pop(name)
    if expose_venv:
        for name in _SHARED_ATTRS:
            if name in kwargs:
                venv_kwargs[name] = kwargs[name]
    return venv_kwargs

def _venv_target_config(name, safe_name, expose_venv, visibility):
    """Return ``(label, visibility, tags, rule_fn)`` for the sibling venv."""
    if expose_venv:
        return "{}.venv".format(name), visibility, None, py_venv
    return "_{}.venv".format(safe_name), ["//visibility:private"], ["manual"], _py_venv_lib

def py_binary_with_venv(
        py_rule,
        name,
        main,
        srcs = [],
        deps = [],
        data = [],
        imports = [],
        tags = None,
        testonly = None,
        visibility = None,
        isolated = True,
        expose_venv = None,
        expose_venv_link = False,
        **kwargs):
    """Split ``py_rule(name, ...)`` into a sibling py_venv + a launcher.

    Called for every ``py_binary`` / ``py_test`` macro invocation.

    ``expose_venv = True`` emits a public ``:{name}.venv`` py_venv:
    runnable and pairable with ``py_venv_link`` for IDE integration.
    ``expose_venv_link = True`` additionally emits a
    ``:{name}.venv_link`` target; implies ``expose_venv = True``.

    ``data`` lands on both targets: the venv merges it into runfiles
    (inherited by every consumer), while the launcher needs it directly
    for ``$(location)`` expansion and the coverage walk.  ``srcs`` is
    similarly duplicated so label resolution works on both sides.
    """
    if expose_venv_link:
        if expose_venv == False:
            fail("py_binary/py_test {!r}: expose_venv_link = True requires a public venv to link, but expose_venv = False was passed explicitly. Drop expose_venv = False, or set expose_venv_link = False.".format(name))
        expose_venv = True
    else:
        expose_venv = bool(expose_venv)

    venv_kwargs = _split_kwargs_for_venv(kwargs, expose_venv)
    venv_kwargs["srcs"] = srcs
    venv_kwargs["deps"] = deps
    venv_kwargs["imports"] = imports
    venv_kwargs["data"] = data

    safe_name = name.replace("/", "_")
    venv_label, venv_visibility, venv_tags, venv_rule = _venv_target_config(
        name,
        safe_name,
        expose_venv,
        visibility,
    )

    venv_rule(
        name = venv_label,
        testonly = testonly,
        visibility = venv_visibility,
        tags = venv_tags,
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
        data = data,
        tags = tags,
        testonly = testonly,
        visibility = visibility,
        venv = ":" + venv_label,
        isolated = isolated,
        **kwargs
    )

def py_venv_link(name, venv, link_name = None, **kwargs):
    """Emit a runnable target that materialises *venv* into the workspace.

    ``bazel run :<name>`` creates a symlink in
    ``$BUILD_WORKING_DIRECTORY`` that points at the target's complete
    runfiles tree.  The command prints the venv's nested path below that
    link, suitable for pointing an IDE at.  Requires directory-based
    runfiles; a manifest alone cannot expose a runfiles tree.

    Args:
        name: Runnable target name.
        venv: Label of a ``py_venv`` target to link.
        link_name: Workspace-relative basename for the runfiles symlink.
            Defaults to a safely-escaped version of the target's package
            + venv name.
        **kwargs: Forwarded to the underlying ``py_venv_exec``.
    """
    link_script = str(Label("templates/link.py"))
    _py_venv_exec(
        name = name,
        main = link_script,
        srcs = [link_script],
        args = [] + (["--name=" + link_name] if link_name else []),
        venv = venv,
        isolated = False,
        **kwargs
    )
