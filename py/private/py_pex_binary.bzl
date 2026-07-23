"""Create a zip file containing a full Python application.

Follows [PEP-441 (PEX)](https://peps.python.org/pep-0441/)

## Ensuring a compatible interpreter is used

The resulting zip file does *not* contain a Python interpreter.
Users are expected to execute the PEX with a compatible interpreter on the runtime system.

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
load("//py/private:providers.bzl", "PyWheelsInfo")
load("//py/private:py_info.bzl", "PyInfo")
load("//py/private/py_venv:types.bzl", "PY_VENV_KINDS", "VirtualenvInfo", "venv_root")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN", "interpreter_files_and_version")

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

def _closure_aspect_impl(target, ctx):
    # Toolchain node, reached via toolchains_aspects: surface the interpreter's
    # repo roots and version for the venv node below to read under its config.
    if platform_common.ToolchainInfo in target:
        files, version = interpreter_files_and_version(target)
        roots = {}
        if files != None:
            for f in files.to_list():
                r = _repo_root_prefix(f.short_path)
                if r != None:
                    roots[r] = True
        return [_PexClosureInfo(
            wheels = depset(),
            venv_roots = depset(),
            interpreter_roots = depset(roots.keys()),
            version = version,
        )]

    wheels = []
    roots = []
    interp = []

    # `version` is the binary's own interpreter version: it flows only from the
    # `venv`/`actual` hop or a venv node's toolchain, never from deps/data (which
    # carry other binaries' interpreters).
    version = None
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
    venv = getattr(ctx.rule.attr, "venv", None)
    if venv != None:
        if _PexClosureInfo in venv:
            wheels.append(venv[_PexClosureInfo].wheels)
            roots.append(venv[_PexClosureInfo].venv_roots)
            interp.append(venv[_PexClosureInfo].interpreter_roots)
            version = venv[_PexClosureInfo].version
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

    return [_PexClosureInfo(
        wheels = depset(transitive = wheels),
        venv_roots = depset(transitive = roots),
        interpreter_roots = depset(transitive = interp),
        version = version,
    )]

_closure_aspect = aspect(
    implementation = _closure_aspect_impl,
    attr_aspects = ["deps", "data", "actual", "venv"],
    # Lets the aspect read `ctx.rule.toolchains[PY_TOOLCHAIN]` at py_venv nodes.
    toolchains_aspects = [PY_TOOLCHAIN],
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

    ctx.actions.run(
        executable = ctx.executable._pex,
        toolchain = None,
        inputs = runfiles.files,
        arguments = [args],
        outputs = [output],
        mnemonic = "PyPex",
        progress_message = "Building PEX binary %{label}",
    )

    return [
        DefaultInfo(files = depset([output]), executable = output),
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
    "_pex": attr.label(executable = True, cfg = "exec", default = "//py/tools/pex"),
})

py_pex_binary = rule(
    doc = "Build a pex executable from a py_binary",
    implementation = _py_python_pex_impl,
    attrs = _attrs,
    executable = True,
)
