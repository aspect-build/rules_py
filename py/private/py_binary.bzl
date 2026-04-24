"""Implementation for the py_binary and py_test rules."""

load("@bazel_lib//lib:expand_make_vars.bzl", "expand_locations", "expand_variables")
load("@bazel_lib//lib:paths.bzl", "BASH_RLOCATION_FUNCTION", "to_rlocation_path")
load("@rules_python//python:defs.bzl", "PyInfo")
load("//py/private:py_library.bzl", _py_library = "py_library_utils")
load("//py/private:py_semantics.bzl", _py_semantics = "semantics")
load("//py/private:venv.bzl", "assemble_venv")
load("//py/private/py_venv:types.bzl", "VirtualenvInfo")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN")
load(":transitions.bzl", "python_version_transition")

def _dict_to_exports(env):
    return [
        "export %s=\"%s\"" % (k, v)
        for (k, v) in env.items()
    ]

def _check_venv_coverage(ctx, imports_depset, wheels_depset, vinfo):
    """Analysis-time check: everything the binary needs must live in the venv.

    The external venv's .pth file is what puts its own deps on sys.path at
    runtime. We can't augment that from the binary's launcher under `-I`
    (which blocks PYTHONPATH). So any first-party import or wheel dep the
    binary declares that the venv doesn't already cover is a guaranteed
    runtime ImportError — catch it at analysis instead.
    """
    venv_imports = {imp: True for imp in vinfo.imports.to_list()}
    bin_wheel_sps = {w.site_packages_rfpath: w for w in wheels_depset.to_list()}

    # Classify missing imports: wheel site-packages vs first-party. Wheel
    # paths get reported by top-level names (readable) instead of repo
    # paths (ugly).
    missing_wheel_names = []
    missing_first_party = []
    for imp in imports_depset.to_list():
        if imp in venv_imports:
            continue
        wheel = bin_wheel_sps.get(imp)
        if wheel != None:
            names = getattr(wheel, "top_levels", ())
            missing_wheel_names.append(
                ", ".join(sorted(names)) if names else imp,
            )
        else:
            missing_first_party.append(imp)

    if missing_wheel_names or missing_first_party:
        parts = []
        if missing_wheel_names:
            parts.append("wheels: " + "; ".join(sorted(missing_wheel_names)))
        if missing_first_party:
            parts.append("first-party imports: " + ", ".join(sorted(missing_first_party)))
        fail(
            ("py_binary {target}: `external_venv = {venv}` doesn't cover " +
             "this binary's dep closure — {details}. Either add the " +
             "missing deps to {venv}, or drop `external_venv` to let the " +
             "binary build its own internal venv.").format(
                target = str(ctx.label),
                venv = str(ctx.attr.external_venv.label),
                details = "; ".join(parts),
            ),
        )

def _py_binary_rule_impl(ctx):
    py_toolchain = _py_semantics.resolve_toolchain(ctx)

    # Resolve our `main=` to a label, which it isn't
    main = _py_semantics.determine_main(ctx)

    # Virtual deps resolve to concrete targets first; imports_depset
    # then gathers first-party + transitive wheel site-packages paths.
    virtual_resolution = _py_library.resolve_virtuals(ctx)
    imports_depset = _py_library.make_imports_depset(ctx, extra_imports_depsets = virtual_resolution.imports)

    # Bazel-contextual env vars that both the launcher (via {{PYTHON_ENV}})
    # and the venv's activate script (via {{ENVVARS}} / {{ENVVARS_UNSET}})
    # export.
    default_env = {
        "BAZEL_TARGET": str(ctx.label).lstrip("@"),
        "BAZEL_WORKSPACE": ctx.workspace_name,
        "BAZEL_TARGET_NAME": ctx.attr.name,
    }

    # Two venv-sourcing modes:
    #
    # * Internal (default): assemble_venv declares every venv file as an
    #   output of this target. Runfiles include the venv files.
    #
    # * External (`external_venv = <py_venv label>`): reuse the venv produced
    #   by another target. Skip assemble_venv entirely. The launcher
    #   exec's the external venv's bin/python; the binary's runfiles
    #   inherit the venv target's default_runfiles so the venv's files
    #   land at their usual rlocation paths. We enforce that the binary's
    #   dep closure is a subset of the venv's at analysis time — the
    #   external venv's .pth is the only mechanism putting deps on
    #   sys.path under our `-I` flag, so un-covered deps would just be
    #   runtime ImportErrors otherwise.
    safe_name = ctx.attr.name.replace("/", "_")
    external_venv = ctx.attr.external_venv
    wheels_depset = _py_library.make_wheels_depset(ctx)
    extra_runfiles = []
    extra_runfiles_depsets = [
        ctx.attr._runfiles_lib[DefaultInfo].default_runfiles,
    ]

    if external_venv:
        vinfo = external_venv[VirtualenvInfo]
        _check_venv_coverage(ctx, imports_depset, wheels_depset, vinfo)
        bin_python = vinfo.bin_python
        extra_runfiles_depsets.append(external_venv[DefaultInfo].default_runfiles)
    else:
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
        )
        bin_python = venv.bin_python
        extra_runfiles = venv.all_files

    # Merge env vars: start from the external venv's `env` (if any),
    # then overlay the binary's own — binary wins on key conflicts.
    # Same merge for inherited env-var names.
    passed_env = {}
    inherited_env = []
    if external_venv and RunEnvironmentInfo in external_venv:
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
            "{{ARG_VENV_PYTHON}}": to_rlocation_path(ctx, bin_python),
            "{{ENTRYPOINT}}": to_rlocation_path(ctx, main),
            "{{PYTHON_ENV}}": "\n".join(_dict_to_exports(default_env)).strip(),
        },
        is_executable = True,
    )

    srcs_depset = _py_library.make_srcs_depset(ctx)

    runfiles = _py_library.make_merged_runfiles(
        ctx,
        extra_depsets = [
            py_toolchain.files,
            srcs_depset,
        ] + virtual_resolution.srcs + virtual_resolution.runfiles,
        extra_runfiles = extra_runfiles,
        extra_runfiles_depsets = extra_runfiles_depsets,
    )

    instrumented_files_info = _py_library.make_instrumented_files_info(
        ctx,
        extra_source_attributes = ["main"],
    )

    default_info_files = [executable_launcher, main]
    if not external_venv:
        default_info_files = default_info_files + extra_runfiles

    return [
        DefaultInfo(
            files = depset(default_info_files),
            executable = executable_launcher,
            runfiles = runfiles,
        ),
        PyInfo(
            imports = imports_depset,
            transitive_sources = srcs_depset,
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
        doc = """Build this binary against an externally-provided virtualenv.

When set, the binary skips its own per-target venv assembly and instead
exec's the referenced venv's `bin/python`. Typical shape:

```
py_venv(
    name = "venv",
    deps = ["@pypi//fastapi", "@pypi//uvicorn"],
)

py_binary(
    name = "serve",
    srcs = ["serve.py"],
    main = "serve.py",
    external_venv = ":venv",
)
```

The binary's dep closure is required to be a **subset** of the venv's:
any first-party import or wheel dep this binary declares that the venv
doesn't already cover is rejected at analysis time. This is a hard
constraint because the venv's `.pth` file is the only channel putting
deps on `sys.path` under `-I` (which blocks `PYTHONPATH`) — un-covered
deps would just be runtime ImportErrors otherwise.

Leave unset (the default) to keep the per-binary internal-venv behaviour.
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
launcher then respects `PYTHONPATH` and loads user site-packages if
`include_user_site_packages` is also true. The deprecated
`py_venv_binary` / `py_venv_test` aliases default this to False to
match their historical permissive behaviour.""",
    ),
    "package_collisions": attr.string(
        doc = """What to do when two wheels both claim the same top-level name.

Wheels contribute top-level names via `PyWheelsInfo` (populated by the
uv `whl_install` repo rule from each wheel's `*.dist-info/RECORD`).

* "error": Fail analysis with a message naming both wheels.
* "warning" (default): Print a warning and use the first wheel seen.
* "ignore": Use the first wheel silently; the second is skipped.

The default is `"warning"` because legitimate top-level overlaps are
common in the Python ecosystem: setuptools vendors `packaging`,
multi-package distributions split the `<root>.*` namespace across
wheels (apache-airflow, jaraco.*), etc. First-seen wins matches what
pip / uv give you at install time. Set this to `"error"` for strict
non-overlap (useful during project hygiene audits).

PEP 420 namespace packages (empty `<root>/` across wheels) are
automatically skipped — they're not real collisions.
""",
        default = "warning",
        values = ["error", "warning", "ignore"],
    ),
    "include_system_site_packages": attr.bool(
        doc = """`pyvenv.cfg` `include-system-site-packages` key. When True,
the host interpreter's site-packages participate in sys.path. Default False
for hermeticity; only flip on to match legacy `python -m venv` behavior or
when system-installed packages need to be reachable.""",
        default = False,
    ),
    "include_user_site_packages": attr.bool(
        doc = """Aspect extension key `aspect-include-user-site-packages` in
pyvenv.cfg. When True, `~/.local/lib/pythonX.Y/site-packages/` participates
in sys.path. Default False for hermeticity.""",
        default = False,
    ),
    "_run_tmpl": attr.label(
        allow_single_file = True,
        default = "//py/private:run.tmpl.sh",
    ),
    "_venv_activate_tmpl": attr.label(
        allow_single_file = True,
        default = "//py/private:venv_activate.tmpl.sh",
    ),
    "_virtualenv_shim": attr.label(
        allow_single_file = True,
        default = "//py/private:_virtualenv.py",
    ),
    "_runfiles_lib": attr.label(
        default = "@bazel_tools//tools/bash/runfiles",
    ),
    # Freethreaded Python 3.13+ uses `lib/python<M>.<m>t/site-packages/`
    # — py_semantics reads this to report freethreaded status to
    # assemble_venv so the venv lands at the interpreter-expected path.
    "_freethreaded_flag": attr.label(
        default = "//py/private/interpreter:freethreaded",
    ),
    # Required for py_version attribute
    "_allowlist_function_transition": attr.label(
        default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
    ),
})

_attrs.update(**_py_library.attrs)

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
