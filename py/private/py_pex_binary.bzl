"""Create a zip file containing a full Python application.

Follows [PEP-441 (PEX)](https://peps.python.org/pep-0441/)

## Ensuring a compatible interpreter is used

The resulting zip file does *not* contain a Python interpreter.
Users are expected to execute the PEX with a compatible interpreter on the runtime system,
unless the PEX is built as a [scie](https://docs.pex-tool.org/scie.html) with `scie = "eager"`,
which bundles the interpreter the `binary` runs on.

Use the `python_interpreter_constraints` to provide an error if a wrong interpreter tries to execute the PEX, for example:

```starlark
py_pex_binary(
    python_interpreter_constraints = [
        "CPython=={major}.{minor}.{patch}",
    ]
)
```
"""

load("@bazel_lib//lib:paths.bzl", "to_rlocation_path")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//py/private:providers.bzl", "PyWheelsInfo")
load("//py/private:py_info.bzl", "PyInfo")
load("//py/private/py_venv:types.bzl", "PY_VENV_KINDS", "VirtualenvInfo", "venv_root")
load("//py/private/py_venv:virtuals_resolvers.bzl", "VENV_OWNED_ROOTS")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN", "interpreter_files_and_version", "interpreter_pbs_archive")

def _runfiles_path(file, workspace):
    if file.short_path.startswith("../"):
        return file.short_path[3:]
    else:
        return workspace + "/" + file.short_path

def _repo_root_prefix(short_path):
    # Runfiles-relative repo root (`../<repo>/`) of an external file, or None for
    # a main-repo file. Excluding the whole hermetic interpreter repo this way
    # also drops its bundled pip/setuptools site-packages.
    if not short_path.startswith("../"):
        return None
    parts = short_path.split("/", 2)
    if len(parts) < 2:
        return None
    return parts[0] + "/" + parts[1] + "/"

# Carries what no public provider exposes on the binary target: wheels reached
# through `data`, sibling venv roots, and the interpreter resolved under the
# binary's `python_version`. A private provider because a leaf that already emits
# PyWheelsInfo may not re-`provides` it ("provided twice").
_PexClosureInfo = provider(
    doc = "Private: wheels, venv roots, interpreter repo roots, and interpreter version aggregated across a binary's closure by _closure_aspect.",
    fields = {
        "wheels": "depset of wheel record structs (see PyWheelsInfo.wheels).",
        "venv_roots": "depset[str] — runfiles-relative roots of every sibling py_venv in the closure.",
        "interpreter_roots": "depset[str] — runfiles-relative repo roots (`../<repo>/`) of every py_venv toolchain's hermetic interpreter in the closure.",
        "version": "struct(major, minor, micro) | None — the binary's own interpreter version; propagated only along the `venv`/`actual` edge, so it is the version the PEX is built for.",
        "freethreaded": "bool | None — whether the binary's venv resolved under free-threaded mode; propagated with `version`.",
        "pbs_archive": "File | None — the PBS archive of the binary's own interpreter, set only under `scie`; propagated with `version`.",
    },
)

def _label_targets(attr_val):
    # The aspect reaches arbitrary rules through runtime data, where an attr
    # named deps/data/srcs is not guaranteed to be a label_list — it may be a
    # scalar label, a dict, or an unrelated value. Keep only Targets; ignore
    # every other shape.
    if type(attr_val) == "list":
        return [v for v in attr_val if type(v) == "Target"]
    if type(attr_val) == "Target":
        return [attr_val]
    return []

def _single_target(value):
    if type(value) == "list":
        return value[0] if len(value) == 1 else None
    return value

def _closure_aspect_impl(target, ctx):
    # Toolchain node, reached via toolchains_aspects: surface the interpreter's
    # repo roots and version for the venv node below to read under its config.
    if platform_common.ToolchainInfo in target:
        files, version = interpreter_files_and_version(target)
        roots = set()
        if files != None:
            for f in files.to_list():
                r = _repo_root_prefix(f.short_path)
                if r != None:
                    roots.add(r)
        return [_PexClosureInfo(
            wheels = depset(),
            venv_roots = depset(),
            interpreter_roots = depset(list(roots)),
            version = version,
            freethreaded = None,
            pbs_archive = interpreter_pbs_archive(target),
        )]

    wheels = []
    roots = []
    interp = []

    # `version` is the binary's own interpreter version: it flows only from the
    # `venv`/`actual` hop or a venv node's toolchain, never from deps/data (which
    # carry other binaries' interpreters). `freethreaded` travels with it.
    version = None
    freethreaded = None
    pbs_archive = None
    for attr_name in ["deps", "data"]:
        for dep in _label_targets(getattr(ctx.rule.attr, attr_name, None)):
            if _PexClosureInfo in dep:
                wheels.append(dep[_PexClosureInfo].wheels)
                roots.append(dep[_PexClosureInfo].venv_roots)
                interp.append(dep[_PexClosureInfo].interpreter_roots)

    # `srcs` is not an aspect edge, so a wheel wrapped there (e.g. the common
    # `filegroup(srcs = [wheel])` data wrapper) is never visited and carries no
    # _PexClosureInfo. Read its own PyWheelsInfo directly; a py_library there
    # already aggregates its subtree's wheels, so one hop suffices.
    for dep in _label_targets(getattr(ctx.rule.attr, "srcs", None)):
        if PyWheelsInfo in dep:
            wheels.append(dep[PyWheelsInfo].wheels)

    # py_venv_exec (what the py_binary macro expands to) routes srcs/deps onto a
    # sibling py_venv reached via `venv`; that venv also carries VirtualenvInfo.
    venv = _single_target(getattr(ctx.rule.attr, "venv", None))
    if venv != None:
        if _PexClosureInfo in venv:
            wheels.append(venv[_PexClosureInfo].wheels)
            roots.append(venv[_PexClosureInfo].venv_roots)
            interp.append(venv[_PexClosureInfo].interpreter_roots)
            version = venv[_PexClosureInfo].version
            freethreaded = venv[_PexClosureInfo].freethreaded
            pbs_archive = venv[_PexClosureInfo].pbs_archive
        if VirtualenvInfo in venv:
            roots.append(depset([venv_root(venv[VirtualenvInfo].bin_python)]))

    # `actual` is a scalar Label on aliases; some rules expose it as a
    # label_list, which no venv alias uses, so we only hop the scalar form.
    actual = getattr(ctx.rule.attr, "actual", None)
    if actual != None and type(actual) != "list" and _PexClosureInfo in actual:
        wheels.append(actual[_PexClosureInfo].wheels)
        roots.append(actual[_PexClosureInfo].venv_roots)
        interp.append(actual[_PexClosureInfo].interpreter_roots)
        if version == None:
            version = actual[_PexClosureInfo].version
        if freethreaded == None:
            freethreaded = actual[_PexClosureInfo].freethreaded
        if pbs_archive == None:
            pbs_archive = actual[_PexClosureInfo].pbs_archive

    # Fires on every py_library, not just wheel leaves: its PyWheelsInfo already
    # aggregates deps + `resolutions`, which is the only path by which
    # resolution-only wheels (the aspect doesn't walk that edge) reach here.
    if PyWheelsInfo in target:
        wheels.append(target[PyWheelsInfo].wheels)

    if ctx.rule.kind in PY_VENV_KINDS and PY_TOOLCHAIN in ctx.rule.toolchains:
        py_tc = ctx.rule.toolchains[PY_TOOLCHAIN]
        if _PexClosureInfo in py_tc:
            interp.append(py_tc[_PexClosureInfo].interpreter_roots)
            version = py_tc[_PexClosureInfo].version
            pbs_archive = py_tc[_PexClosureInfo].pbs_archive

        # The venv node analyzes under its own transitioned configuration, so
        # the flag here reflects the binary's resolved free-threaded mode.
        freethreaded = ctx.attr._freethreaded[BuildSettingInfo].value

    return [_PexClosureInfo(
        wheels = depset(transitive = wheels),
        venv_roots = depset(transitive = roots),
        interpreter_roots = depset(transitive = interp),
        version = version,
        freethreaded = freethreaded,
        pbs_archive = pbs_archive,
    )]

_closure_aspect = aspect(
    implementation = _closure_aspect_impl,
    attr_aspects = ["deps", "data", "actual", "venv"],
    # Lets the aspect read `ctx.rule.toolchains[PY_TOOLCHAIN]` at py_venv nodes.
    toolchains_aspects = [PY_TOOLCHAIN],
    attrs = {
        "_freethreaded": attr.label(default = "//py/private/interpreter:freethreaded"),
    },
    provides = [_PexClosureInfo],
)

def _dep_arg(wheel):
    # pex `--dependency` wants the exec-root site-packages dir. Graft the
    # trailing `lib/<pyver>/site-packages` (copied verbatim from the producer's
    # site_packages_rfpath) onto the install tree; one dist per tree.
    suffix = "/".join(wheel.site_packages_rfpath.rsplit("/", 3)[1:])
    return "--dependency={}/{}".format(wheel.install_tree.path, suffix)

def _py_python_pex_impl(ctx):
    binary = ctx.attr.binary
    binary_default = binary[DefaultInfo]

    # py_venv_exec emits depset([launcher, main]) — the non-executable file is
    # the Python entrypoint the launcher exec's.
    entrypoint_files = [f for f in binary_default.files.to_list() if f != binary_default.files_to_run.executable]
    if len(entrypoint_files) != 1:
        fail("py_pex_binary {}: expected exactly one entrypoint file in `binary` DefaultInfo.files, got {}".format(ctx.label, entrypoint_files))
    entrypoint = entrypoint_files[0]

    closure = binary[_PexClosureInfo]
    if closure.version == None:
        fail("py_pex_binary {}: could not resolve the binary's interpreter version from its venv toolchain.".format(ctx.label))

    # PEX interpreter constraints cannot express the free-threaded ABI, so a
    # standard (GIL) interpreter of the same version would accept the PEX and
    # fail at import time on its cpXYt wheels.
    if closure.freethreaded:
        fail("py_pex_binary {}: `binary` targets a free-threaded interpreter, which PEX interpreter constraints cannot express; use freethreaded = False on the binary.".format(ctx.label))

    wheels = closure.wheels
    wheels_list = wheels.to_list()
    runfiles = binary_default.data_runfiles

    # --source packages everything in runfiles except what is packaged another
    # way: wheel trees go out as --dependency; the interpreter repos and venv
    # plumbing aren't packaged. `add_all` expands the wheel tree artifacts before
    # `map_each`, so we match the expanded children against the tree's exec-root
    # path prefix (the unexpanded tree artifact never would).
    wheel_tree_prefixes = [w.install_tree.path + "/" for w in wheels_list]
    interpreter_prefixes = closure.interpreter_roots.to_list()
    venv_prefixes = [r + "/" for r in closure.venv_roots.to_list()]

    # PEP 427 `.data/data/` files sit outside the site-packages that
    # `--dependency` packages, so the wheel-tree exclusion below would drop them.
    # Keep them as sources at the runfiles path they occupy outside the PEX, so
    # a runfiles-relative lookup resolves the same either way. The venv's
    # `sys.prefix` projection has no PEX analogue: a zipapp runs under the
    # ambient interpreter, whose prefix is not the PEX.
    #
    # Venv-owned prefix roots are excluded on the same terms as venv assembly
    # (see `VENV_OWNED_ROOTS`): a wheel's `bin/`, `lib/`, or `pyvenv.cfg` data
    # file is not projected into a venv, so shipping it here would make the PEX
    # carry a file its venv counterpart deliberately drops.
    data_file_paths = {
        w.install_tree.path + "/" + path: True
        for w in wheels_list
        for path in getattr(w, "data_files", ())
        if path.split("/")[0] not in VENV_OWNED_ROOTS
    }

    output = ctx.actions.declare_file(ctx.attr.name + ".pex")

    args = ctx.actions.args()
    args.use_param_file(param_file_arg = "@%s")
    args.set_param_file_format("multiline")

    # A local (not ctx.workspace_name inline) keeps ctx out of the map_each
    # closures below, which allow_closure ships to the execution phase.
    workspace_name = ctx.workspace_name

    args.add_all(
        ctx.attr.inject_env.items(),
        map_each = lambda e: "--inject-env={}={}".format(e[0], e[1]),
        allow_closure = True,
    )

    args.add_all(binary[PyInfo].imports, format_each = "--sys-path=%s")

    args.add_all(wheels, map_each = _dep_arg)

    def _map_source(f):
        sp = f.short_path
        for prefix in interpreter_prefixes:
            if sp.startswith(prefix):
                return []
        for prefix in venv_prefixes:
            if sp.startswith(prefix):
                return []
        p = f.path
        if p not in data_file_paths:
            for prefix in wheel_tree_prefixes:
                if p.startswith(prefix):
                    return []
        return ["--source={}={}".format(p, _runfiles_path(f, workspace_name))]

    args.add_all(
        runfiles.files,
        map_each = _map_source,
        allow_closure = True,
    )

    args.add(to_rlocation_path(ctx, entrypoint), format = "--entrypoint=%s")
    args.add(ctx.attr.python_shebang, format = "--python-shebang=%s")

    if ctx.attr.inherit_path != "":
        args.add(ctx.attr.inherit_path, format = "--inherit-path=%s")

    # Stamp constraints from the binary's own interpreter version, the one the
    # PEX is built for.
    py_version = closure.version
    args.add_all(
        [
            constraint.format(major = py_version.major, minor = py_version.minor, patch = py_version.micro)
            for constraint in ctx.attr.python_interpreter_constraints
        ],
        format_each = "--python-version-constraint=%s",
    )
    args.add(output, format = "--output-file=%s")

    outputs = [output]
    tools = []
    scie = None
    if ctx.attr.scie:
        if closure.pbs_archive == None:
            fail("py_pex_binary {}: `scie` needs the binary's interpreter to come from rules_py's python_interpreters extension, which provides its python-build-standalone archive.".format(ctx.label))
        if not ctx.files._science or not ctx.files._scie_jump:
            fail("py_pex_binary {}: `scie` is supported only on Linux and macOS, on x86_64 and aarch64.".format(ctx.label))
        scie = ctx.actions.declare_file(ctx.attr.name)
        outputs.append(scie)
        tools = [closure.pbs_archive, ctx.files._science[0], ctx.files._scie_jump[0]]
        args.add(ctx.attr.scie, format = "--scie=%s")
        args.add(closure.pbs_archive, format = "--scie-pbs-archive=%s")
        args.add(ctx.files._science[0], format = "--scie-science=%s")
        args.add(ctx.files._scie_jump[0], format = "--scie-jump=%s")
        args.add(scie, format = "--scie-output-file=%s")

    ctx.actions.run(
        executable = ctx.executable._pex,
        toolchain = None,
        inputs = depset(tools, transitive = [runfiles.files]),
        arguments = [args],
        outputs = outputs,
        mnemonic = "PyPex",
        progress_message = "Building PEX scie %{label}" if scie else "Building PEX binary %{label}",
    )

    # VIRTUAL_ENV names the binary's runfiles venv, which the pex does not carry.
    environment = {}
    inherited_environment = []
    if RunEnvironmentInfo in binary:
        run_env = binary[RunEnvironmentInfo]
        environment = {k: v for k, v in run_env.environment.items() if k != "VIRTUAL_ENV"}
        inherited_environment = run_env.inherited_environment
    environment["BAZEL_TARGET"] = str(ctx.label).lstrip("@")
    environment["BAZEL_WORKSPACE"] = ctx.workspace_name
    environment["BAZEL_TARGET_NAME"] = ctx.attr.name

    return [
        DefaultInfo(files = depset([scie or output]), executable = scie or output),
        OutputGroupInfo(pex = depset([output])),
        RunEnvironmentInfo(
            environment = environment,
            inherited_environment = inherited_environment,
        ),
    ]

_attrs = dict({
    "binary": attr.label(
        executable = True,
        cfg = "target",
        mandatory = True,
        doc = "The py_binary target to package.",
        aspects = [_closure_aspect],
    ),
    "inject_env": attr.string_dict(
        doc = "Environment variables to set when running the pex binary.",
        default = {},
    ),
    "inherit_path": attr.string(
        doc = """\
Whether to inherit the `sys.path` (aka PYTHONPATH) of the environment that the binary runs in.

Use `false` to not inherit `sys.path`; use `fallback` to inherit `sys.path` after packaged
dependencies; and use `prefer` to inherit `sys.path` before packaged dependencies.
""",
        values = ["false", "fallback", "prefer"],
    ),
    "python_shebang": attr.string(default = "#!/usr/bin/env python3"),
    "python_interpreter_constraints": attr.string_list(
        default = ["CPython=={major}.{minor}.*"],
        doc = """\
Python interpreter versions this PEX binary is compatible with. A list of semver strings.
The placeholder strings `{major}`, `{minor}`, `{patch}` are substituted with the version of
the `binary`'s own interpreter, the one the PEX is built for.
""",
    ),
    "scie": attr.string(
        doc = """\
Build a [scie](https://docs.pex-tool.org/scie.html): a native executable that bundles the PEX with
the python-build-standalone interpreter the `binary` runs on, so that it runs without any Python
installed. `eager` embeds the interpreter. The scie is the target's executable, named after the
target; the PEX itself is in the `pex` output group.

The binary's interpreter must come from rules_py's `python_interpreters` extension, and the scie
can only be built for the platform that builds it (Linux or macOS, x86_64 or aarch64).
""",
        values = ["", "eager"],
        default = "",
    ),
    "_pex": attr.label(executable = True, cfg = "exec", default = "//py/tools/pex"),
    # Empty unless `scie` is set; see //py/tools/pex:science.
    "_science": attr.label(default = "//py/tools/pex:science", allow_files = True),
    "_scie_jump": attr.label(default = "//py/tools/pex:scie_jump", allow_files = True),
    "_allowlist_function_transition": attr.label(
        default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
    ),
})

_PEX_SCIE_FLAG = str(Label("//py/private/interpreter:pex_scie"))

def _scie_transition_impl(_settings, attr):
    # Gates the interpreter's PBS archive and the science tools, so that only a
    # scie build fetches them.
    return {_PEX_SCIE_FLAG: attr.scie != ""}

_scie_transition = transition(
    implementation = _scie_transition_impl,
    inputs = [],
    outputs = [_PEX_SCIE_FLAG],
)

py_pex_binary = rule(
    doc = """\
Build a pex executable from a py_binary.

`bazel run` on the pex gets the `binary`'s `env` and `env_inherit`, with
`BAZEL_TARGET`, `BAZEL_TARGET_NAME` and `BAZEL_WORKSPACE` naming the pex.
`env` paths must use `$(rlocationpath)`: the pex resolves runfiles from its own
archive, so `$(rootpath)`, `$(location)` and `$(execpath)` values do not exist.
Outside of Bazel only `inject_env` applies.
""",
    implementation = _py_python_pex_impl,
    attrs = _attrs,
    cfg = _scie_transition,
    executable = True,
)
