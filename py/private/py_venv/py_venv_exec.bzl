"""Implementation for the py_venv_exec and py_venv_exec_test rules.

Both are thin launchers that consume a sibling `py_venv` (passed via the
internal `venv` attr) and exec its `bin/python`. The public
`py_binary` / `py_test` macros wrap them and route all venv-shaping
attrs to the auto-generated sibling.
"""

load("@bazel_lib//lib:expand_make_vars.bzl", "expand_locations", "expand_variables")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@hermetic_launcher//launcher:lib.bzl", "launcher")
load("//py/private:py_info.bzl", "PyInfo")
load("//py/private:py_info_interop.bzl", "RulesPythonPyInfo", "get_py_info", "has_py_info")
load("//py/private:py_semantics.bzl", _py_semantics = "semantics")
load("//py/private:pyc.bzl", "FirstPartyPycInfo", "FirstPartyPycModeInfo", "first_party_pyc_aspect")
load("//py/private:transitions.bzl", "python_transition", "reset_python_flags_transition")
load(":types.bzl", "VirtualenvInfo", "venv_root")

# Identifiers the launcher always sets to the analysing rule's contextual
# values. Excluded from `inherited_environment` so that a stray
# `env_inherit` entry can't let an outer shell shadow the contextual
# label at run time.
_CONTEXTUAL_ENV_KEYS = ("BAZEL_TARGET", "BAZEL_WORKSPACE", "BAZEL_TARGET_NAME")

def _pyc_entry_for(by_source, source):
    # The sibling venv is in a Python-transitioned configuration while `main`
    # remains in the launcher's configuration. Generated sources can therefore
    # have different exec paths but the same runfiles path.
    entry = by_source.get(source.short_path)
    return entry.pyc if entry != None else None

def _pyc_mode(ctx):
    if _single_venv(ctx.attr.pyc_venv, "pyc_venv") == None:
        if ctx.attr.pyc in ("pyc", "pyc_only"):
            fail("{}: pyc={} requires pyc_venv so the bytecode aspect is applied".format(ctx.label, ctx.attr.pyc))
        return "source"
    mode = ctx.attr.pyc or "pyc"
    if mode == "pyc_only" and ctx.configuration.coverage_enabled:
        # Coverage instruments .py sources; sourceless runfiles would silently
        # collect empty coverage data.
        return "source"
    return mode

def _single_venv(value, attr_name):
    if type(value) == "list":
        if not value:
            return None
        if len(value) != 1:
            fail("{} must resolve to exactly one venv, got {}".format(attr_name, len(value)))
        return value[0]
    return value

def _py_venv_exec_impl(ctx):
    # The launcher itself doesn't need a python toolchain — it just
    # exec's the sibling venv's `bin/python`, whose path was already
    # resolved when the venv was analysed. Default interpreter flags
    # come from a shared constant.
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

    source_venv = _single_venv(ctx.attr.venv, "venv")
    pyc_venv = _single_venv(ctx.attr.pyc_venv, "pyc_venv")
    if source_venv != None and pyc_venv != None:
        fail("{}: venv and pyc_venv are mutually exclusive".format(ctx.label))
    venv = pyc_venv if pyc_venv != None else source_venv
    if venv == None:
        fail("{}: one of venv or pyc_venv must be set".format(ctx.label))
    vinfo = venv[VirtualenvInfo]
    bytecode_mode = _pyc_mode(ctx)
    include_pyc = bytecode_mode in ("pyc", "pyc_only")
    use_pyc = bytecode_mode == "pyc_only"
    pyc_info = None
    pyc_by_source = {}
    if include_pyc:
        if FirstPartyPycInfo not in venv:
            fail("{}: bytecode mode requires pyc_venv so the bytecode aspect is applied".format(ctx.label))
        pyc_info = venv[FirstPartyPycInfo]
    entrypoint = main
    if use_pyc:
        # Only sourceless mode needs reverse lookup/completeness validation;
        # ordinary pyc mode merely merges the provider's depsets.
        pyc_by_source = {entry.source.short_path: entry for entry in pyc_info.entries.to_list()}
        missing = [
            src.short_path
            for src in vinfo.transitive_sources.to_list()
            if src.extension == "py" and src.short_path not in pyc_by_source
        ]
        if missing:
            fail("{}: pyc_only could not compile all first-party sources: {}".format(
                ctx.label,
                ", ".join(sorted(missing)),
            ))
        entrypoint = _pyc_entry_for(pyc_by_source, main)
        if entrypoint == None:
            fail(("{}: pyc_only requested but no bytecode was produced for main {}. " +
                  "The source must be directly owned by a rules_py py_* target and the exec " +
                  "Python must exactly match the target Python version.").format(ctx.label, main))

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

    # Owned by the rule. The lib venv variant carries no `env` to guard,
    # so guard here to match the executable variant's check.
    if "VIRTUAL_ENV" in ctx.attr.env:
        fail("py_binary/py_test {}: `VIRTUAL_ENV` is set by the rule and cannot be overridden via `env`.".format(ctx.label))

    # Set here so it's present even for the lib venv variant, which has
    # no RunEnvironmentInfo to carry it.
    passed_env["VIRTUAL_ENV"] = venv_root(vinfo.bin_python)
    for k, v in ctx.attr.env.items():
        passed_env[k] = expand_variables(
            ctx,
            expand_locations(ctx, v, ctx.attr.data),
            attribute_name = "env",
        )
    for name in ctx.attr.env_inherit:
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
    embedded_args, transformed_args = launcher.args_from_entrypoint(vinfo.bin_python)
    for flag in flags:
        embedded_args, transformed_args = launcher.append_embedded_arg(
            arg = flag,
            embedded_args = embedded_args,
            transformed_args = transformed_args,
        )
    embedded_args, transformed_args = launcher.append_runfile(
        file = entrypoint,
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
    data_sources = [
        get_py_info(target).transitive_sources
        for target in ctx.attr.data
        if has_py_info(target)
    ]

    # PYC vs source files
    if use_pyc:
        # The pyc outputs are declared sibling to their sources, so their
        # natural runfiles paths are the required legacy ``foo.pyc`` paths.
        # Data targets stay in source form; their sources merge as-is.
        venv_files = pyc_info.legacy_files
    elif include_pyc:
        venv_files = depset(transitive = [vinfo.transitive_sources, pyc_info.pycache_files])
    else:
        venv_files = vinfo.transitive_sources

    runfiles = ctx.runfiles(
        # `main` may be outside the venv's `srcs`; source-retaining modes
        # continue to attach it independently. In pyc_only it is supplied by
        # `venv_files` as the compiled entrypoint.
        files = ctx.files.data + ([] if use_pyc else [main]),
        transitive_files = depset(transitive = [venv_files] + data_sources),
    ).merge(vinfo.runtime_runfiles).merge_all(
        [target[DefaultInfo].default_runfiles for target in ctx.attr.data],
    )

    instrumented_files_info = coverage_common.instrumented_files_info(
        ctx,
        source_attributes = ["main"],
        dependency_attributes = ["data", "venv", "pyc_venv"],
        extensions = ["py"],
    )

    providers = [
        DefaultInfo(
            files = depset([executable_launcher, entrypoint]),
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
            virtual_dependencies = depset(),
            virtual_resolutions = depset(),
        ),
        instrumented_files_info,
        RunEnvironmentInfo(
            environment = passed_env,
            inherited_environment = inherited_env,
        ),
        FirstPartyPycModeInfo(mode = bytecode_mode),
    ]
    if include_pyc:
        providers.append(FirstPartyPycInfo(
            entries = pyc_info.entries,
            legacy_files = pyc_info.legacy_files,
            pycache_files = pyc_info.pycache_files,
        ))

    if ctx.attr._emit_rules_python_providers[BuildSettingInfo].value:
        providers.append(RulesPythonPyInfo(
            imports = vinfo.imports,
            transitive_sources = vinfo.transitive_sources,
        ))

    return providers

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
        doc = """
Script to execute with the Python interpreter.

Required. Must be a label pointing to a `.py` source file.
""",
    ),
    "venv": attr.label(
        providers = [[VirtualenvInfo]],
        cfg = python_transition,
        doc = """Internal: source-mode py_venv edge, set by the `py_venv_exec`
macro. This edge intentionally has no bytecode aspect.""",
    ),
    "pyc_venv": attr.label(
        providers = [[VirtualenvInfo]],
        cfg = python_transition,
        aspects = [first_party_pyc_aspect],
        doc = """Internal: bytecode-mode py_venv edge, set by the
`py_venv_exec` macro. It is separate from `venv` so source-mode targets do
not apply the bytecode aspect.

The binary's launcher exec's the referenced venv's `bin/python`; its
runfiles inherit the venv's default_runfiles for wheels and runtime data,
and add first-party sources from `VirtualenvInfo.transitive_sources` at
their usual rlocation paths.
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
launcher then respects `PYTHONPATH` and loads user site-packages. The
deprecated `py_venv_binary` / `py_venv_test` aliases default this to
False to match their historical permissive behaviour.""",
    ),
    "pyc": attr.string(
        default = "",
        values = ["", "source", "pyc", "pyc_only"],
        doc = """Internal: bytecode mode for the `pyc_venv` edge, set by the
`py_venv_exec` macro; empty defaults to `pyc` on that edge. A
`select()`-routed mode resolves here at analysis time, so every branch —
including `source` — analyzes the bytecode aspect (its compile actions stay
unexecuted in source branches).""",
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
Data is analyzed in the inherited caller configuration. Put artifacts
that must match the terminal's Python environment in `deps`.
""",
        allow_files = True,
        cfg = reset_python_flags_transition,
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
    "python_version": attr.string(
        default = "",
        doc = "Python version for this direct py_venv_exec consumer. Usually set on py_binary/py_test instead.",
    ),
    "_allowlist_function_transition": attr.label(
        default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
    ),
    "_emit_rules_python_providers": attr.label(
        default = "//py/private:emit_rules_python_providers",
    ),
})

_test_attrs = dict({
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

_py_venv_exec = rule(
    doc = "Launcher rule that exec's the interpreter from a sibling `py_venv` (set via `venv`). Most users should use the [py_binary macro](#py_binary) instead of loading this directly.",
    implementation = _py_venv_exec_impl,
    attrs = _attrs,
    executable = True,
    toolchains = [launcher.finalizer_toolchain_type, launcher.template_toolchain_type],
)

_py_venv_exec_test = rule(
    doc = "Test variant of `py_venv_exec`. Most users should use the [py_test macro](#py_test) instead of loading this directly.",
    implementation = _py_venv_exec_impl,
    attrs = _attrs | _test_attrs,
    test = True,
    toolchains = [launcher.finalizer_toolchain_type, launcher.template_toolchain_type],
)

_PYC_SOURCE_CONFIG = str(Label("//py:_pyc_source"))
_PYC_ONLY_CONFIG = str(Label("//py:_pyc_only"))

def _pyc_routed_kwargs(venv, pyc):
    """Route the public (venv, pyc) pair onto the internal edge attrs.

    The bytecode aspect attaches statically to the `pyc_venv` attr, so which
    edge carries the venv IS the mode switch; this helper is the only place
    that mapping lives.
    """
    if type(pyc) != "string":
        # select(): the mode resolves at analysis time, so the aspect-bearing
        # edge must carry the venv in every branch; the rule's `pyc` attr
        # picks the mode (source branches leave compile actions unexecuted).
        return {"pyc_venv": venv, "pyc": pyc}
    if pyc not in ("", "source", "pyc", "pyc_only"):
        fail("pyc must be one of source, pyc, or pyc_only; got {}".format(repr(pyc)))
    if pyc in ("pyc", "pyc_only"):
        return {"pyc_venv": venv, "pyc": pyc}
    if pyc == "source":
        return {"venv": venv}

    # Unset: inherit the `//py:pyc` flag. The carrying edge is
    # config-dependent, so both edges (and the mode) select() on the flag.
    return {
        "venv": select({
            _PYC_SOURCE_CONFIG: venv,
            "//conditions:default": None,
        }),
        "pyc_venv": select({
            _PYC_SOURCE_CONFIG: None,
            "//conditions:default": venv,
        }),
        "pyc": select({
            _PYC_SOURCE_CONFIG: "source",
            _PYC_ONLY_CONFIG: "pyc_only",
            "//conditions:default": "pyc",
        }),
    }

def py_venv_exec(name, venv = None, pyc = "", **kwargs):
    """Launcher that exec's the interpreter from a sibling `py_venv`.

    Most users should use the [py_binary macro](#py_binary) instead.

    Args:
        name: Name of the rule.
        venv: The sibling `py_venv` target providing the environment.
        pyc: First-party bytecode packaging: `"source"`, `"pyc"`, or
            `"pyc_only"`. Empty (the default) inherits the
            `--@aspect_rules_py//py:pyc` flag. A `select()` value is
            accepted.
        **kwargs: Forwarded to the underlying launcher rule.
    """
    routed = _pyc_routed_kwargs(venv, pyc)
    _py_venv_exec(
        name = name,
        venv = routed.get("venv"),
        pyc_venv = routed.get("pyc_venv"),
        pyc = routed.get("pyc", ""),
        **kwargs
    )

def py_venv_exec_test(name, venv = None, pyc = "", **kwargs):
    """Test variant of [py_venv_exec](#py_venv_exec); see it for the arguments.

    Most users should use the [py_test macro](#py_test) instead.

    Args:
        name: Name of the rule.
        venv: The sibling `py_venv` target providing the environment.
        pyc: First-party bytecode packaging; see `py_venv_exec`.
        **kwargs: Forwarded to the underlying launcher rule.
    """
    routed = _pyc_routed_kwargs(venv, pyc)
    _py_venv_exec_test(
        name = name,
        venv = routed.get("venv"),
        pyc_venv = routed.get("pyc_venv"),
        pyc = routed.get("pyc", ""),
        **kwargs
    )
