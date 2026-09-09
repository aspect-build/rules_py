"""First-party Python bytecode compilation.

`PycInfo` is declared unconditionally by `py_library` / `py_venv`; the compile
actions only run when a terminal's `pyc` attribute or the `//py:pyc` flag
requests bytecode, so launchers sharing a configured library share them.
"""

load("@bazel_lib//lib:copy_file.bzl", "COPY_FILE_TOOLCHAINS", "copy_file_action")
load("@bazel_skylib//lib:paths.bzl", "paths")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//py/private:providers.bzl", "PyWheelsInfo")
load("//py/private:py_info_interop.bzl", "RulesPythonPyInfo", "get_py_info", "has_py_info")
load("//py/private:transitions.bzl", "PYC_FLAG")
load("//py/private/toolchain:types.bzl", "EXEC_TOOLS_TOOLCHAIN", "PY_TOOLCHAIN")

PYC_MODES = ["source", "pyc", "pyc_only"]

PycInfo = provider(
    doc = "Private: first-party Python bytecode artifacts.",
    fields = {
        "complete": "bool — whether every transitive Python source has a bytecode entry.",
        "direct_entries": "list[struct(source, pyc, pycache)] — bytecode mappings declared directly by this target.",
        "entries": "depset[struct(source, pyc, pycache)] — transitive bytecode mappings; pyc is the colocated copy of pycache.",
        "legacy_files": "depset[File] — colocated sourceless .pyc files.",
        "missing_sources": "depset[File] — Python sources without bytecode entries.",
        "pycache_files": "depset[File] — PEP 3147 __pycache__ files for source-retaining mode.",
        "sourceless_files": "depset[File] — colocated .pyc files plus non-Python source artifacts retained by pyc_only.",
    },
)

PycModeInfo = provider(
    doc = "Private: effective first-party bytecode mode of a runnable target.",
    fields = {"mode": "One of source, pyc, or pyc_only."},
)

PYC_ATTRS = {
    "_pyc_compiler": attr.label(
        default = "//py/private:pyc_compile.py",
        allow_single_file = True,
    ),
}

# Terminals read the flag as the default for an unset `pyc` attribute.
PYC_MODE_ATTRS = {
    "_pyc_flag": attr.label(
        default = PYC_FLAG,
        providers = [BuildSettingInfo],
    ),
}

# Compilation is optional until a pyc consumer requests complete bytecode.
PYC_TOOLCHAINS = [
    config_common.toolchain_type(PY_TOOLCHAIN, mandatory = False),
    config_common.toolchain_type(EXEC_TOOLS_TOOLCHAIN, mandatory = False),
] + COPY_FILE_TOOLCHAINS

_PRERELEASE_ABBREVS = {"alpha": "a", "beta": "b", "candidate": "rc"}

def own_compile_sources(srcs_targets):
    """Files this target compiles: `srcs` entries that are file labels.

    Files reached through a rule target in `srcs` (filegroup, genrule,
    py_library) stay in source form.

    Args:
        srcs_targets: Targets of the rule's `srcs` attribute.

    Returns:
        list[File] — the compilable sources.
    """
    files = []
    for target in srcs_targets:
        if has_py_info(target):
            continue
        fs = target[DefaultInfo].files.to_list()
        if len(fs) == 1 and _is_file_target(target.label, fs[0]):
            files.append(fs[0])
    return files

def _is_file_target(label, f):
    """Whether `label` names the file itself rather than a rule providing it."""
    owner = f.owner
    if owner == None:
        return False
    if f.is_source:
        return owner == label

    if owner == label:
        return False
    if owner.package != label.package or owner.workspace_name != label.workspace_name:
        return False
    path = f.short_path
    if path.startswith("../"):
        path = path.split("/", 2)[2]
    if label.package:
        path = path[len(label.package) + 1:]
    return path == label.name

def _expected_version(runtime):
    """Version string the compiler must match, or None when unknown."""
    version_info = getattr(runtime, "interpreter_version_info", None)
    if version_info == None:
        return None
    expected = "{}.{}.{}".format(version_info.major, version_info.minor, getattr(version_info, "micro", None) or 0)
    releaselevel = getattr(version_info, "releaselevel", None)
    if releaselevel and releaselevel != "final":
        expected += _PRERELEASE_ABBREVS.get(releaselevel, releaselevel) + str(getattr(version_info, "serial", None) or 0)
    return expected

def _bytecode_key(runtime):
    version_info = getattr(runtime, "interpreter_version_info", None)
    if version_info == None:
        return None

    pyc_tag = getattr(runtime, "pyc_tag", None)
    implementation_name = getattr(runtime, "implementation_name", None)
    if pyc_tag:
        runtime_identity = ("pyc_tag", str(pyc_tag))
    elif implementation_name:
        runtime_identity = ("implementation", str(implementation_name))
    else:
        return None

    key = [
        runtime_identity,
        str(getattr(version_info, "major", None)),
        str(getattr(version_info, "minor", None)),
    ]
    releaselevel = getattr(version_info, "releaselevel", None) or "final"
    if releaselevel != "final":
        key += [
            str(getattr(version_info, "micro", None) or 0),
            releaselevel,
            str(getattr(version_info, "serial", None) or 0),
        ]
    return tuple(key)

def bytecode_compatible(exec_runtime, target_runtime):
    """Whether `exec_runtime` emits bytecode loadable by `target_runtime`.

    Final releases match on implementation/cache tag and major.minor;
    prereleases require an exact version match.
    """
    target_key = _bytecode_key(target_runtime)
    return target_key != None and target_key == _bytecode_key(exec_runtime)

def pycache_tag(runtime):
    """Return the runtime's PEP 3147 cache tag.

    Args:
        runtime: PyRuntimeInfo of the target toolchain.

    Returns:
        The `pyc_tag` field, else `<implementation>-<major><minor>`, else None.
    """
    tag = getattr(runtime, "pyc_tag", None)
    if tag:
        return tag
    implementation_name = getattr(runtime, "implementation_name", None)
    version = getattr(runtime, "interpreter_version_info", None)
    if not implementation_name or version == None:
        return None
    return "{}-{}{}".format(implementation_name, version.major, version.minor)

def compile_pycs(ctx, srcs, existing = {}):
    """Compile this rule's own first-party sources to bytecode.

    Only sources directly owned by this target's package are compiled — a
    ``sibling=`` declaration (which keeps the bytecode's natural runfiles
    location next to its source) is only permitted for files of the declaring
    package. Foreign sources are expected to be compiled by their own owning
    target; the pyc_only terminal validates that none remain.

    Args:
        ctx: rule or aspect ctx carrying PYC_ATTRS and PYC_TOOLCHAINS.
        srcs: list[File] — the rule's direct sources.
        existing: dict[short_path, File] — bytecode the owning target already
            declares at the natural paths; taken instead of compiled.

    Returns:
        struct(entries, legacy_files, pycache_files) of lists; empty lists
        when no bytecode-compatible compiler is available.
    """
    entries = []
    legacy_files = []
    pycache_files = []

    target_toolchain = ctx.toolchains[PY_TOOLCHAIN]
    target_runtime = target_toolchain.py3_runtime if target_toolchain != None else None

    # Prefer a custom tool, then a compatible exec runtime, then the target runtime.
    pyc_compile_tool = getattr(target_toolchain, "pyc_compile_tool", None) if target_toolchain != None else None
    tool_toolchain = PY_TOOLCHAIN
    if pyc_compile_tool == None and target_runtime != None:
        exec_toolchain = ctx.toolchains[EXEC_TOOLS_TOOLCHAIN]
        exec_runtime = getattr(exec_toolchain, "exec_runtime", None) if exec_toolchain != None else None
        compile_runtime = None
        if exec_runtime != None and getattr(exec_runtime, "interpreter", None) != None and bytecode_compatible(exec_runtime, target_runtime):
            compile_runtime = exec_runtime
            tool_toolchain = EXEC_TOOLS_TOOLCHAIN
        elif target_runtime.interpreter != None:
            compile_runtime = target_runtime
        if compile_runtime != None:
            pyc_compile_tool = struct(
                executable = compile_runtime.interpreter,
                arguments = ["-S", "-s", "-B", ctx.file._pyc_compiler],
                inputs = depset(
                    [compile_runtime.interpreter, ctx.file._pyc_compiler],
                    transitive = [compile_runtime.files],
                ),
                supports_workers = True,
            )

    pyc_tag = pycache_tag(target_runtime)
    if target_runtime == None or pyc_compile_tool == None or pyc_tag == None:
        return struct(entries = entries, legacy_files = legacy_files, pycache_files = pycache_files)

    expected_version = _expected_version(target_runtime)

    # Startup arguments stay on the command line; per-source arguments go
    # through a flagfile so a persistent worker receives them per request.
    tool_args = ctx.actions.args()
    tool_args.add_all(pyc_compile_tool.arguments)
    execution_requirements = {}
    if getattr(pyc_compile_tool, "supports_workers", False):
        execution_requirements = {"supports-workers": "1", "requires-worker-protocol": "json"}

    # Per-source actions remain identical when multiple targets share a source.
    for src in srcs:
        if src.extension != "py":
            continue
        if src.owner.package != ctx.label.package or src.owner.workspace_name != ctx.label.workspace_name:
            continue
        stem = src.basename[:-3]
        directory = src.short_path.rpartition("/")[0]
        pycache_basename = "{}.{}.pyc".format(stem, pyc_tag)
        pyc = existing.get(paths.join(directory, stem + ".pyc"))
        pycache = existing.get(paths.join(directory, "__pycache__", pycache_basename))
        if pycache == None:
            pycache = ctx.actions.declare_file("__pycache__/{}".format(pycache_basename), sibling = src)
            compile_args = ctx.actions.args()
            compile_args.set_param_file_format("multiline")
            compile_args.use_param_file("@%s", use_always = True)
            if expected_version:
                compile_args.add("--expect-version", expected_version)
            compile_args.add(src)
            compile_args.add(pycache)
            compile_args.add(src.short_path)
            ctx.actions.run(
                executable = pyc_compile_tool.executable,
                toolchain = tool_toolchain,
                arguments = [tool_args, compile_args],
                execution_requirements = execution_requirements,
                inputs = depset(
                    direct = [src],
                    transitive = [pyc_compile_tool.inputs],
                ),
                outputs = [pycache],
                mnemonic = "PyCompile",
                progress_message = "Python precompiling {} into {}".format(src.short_path, pycache.short_path),
                env = {
                    "PYTHONHASHSEED": "0",
                    "PYTHONNOUSERSITE": "1",
                    "PYTHONSAFEPATH": "1",
                },
            )

        # The sourceless layout is the same bytes, so pyc_only is a copy.
        if pyc == None:
            pyc = ctx.actions.declare_file(stem + ".pyc", sibling = src)
            copy_file_action(ctx, pycache, pyc)
        entries.append(struct(source = src, pyc = pyc, pycache = pycache))
        legacy_files.append(pyc)
        pycache_files.append(pycache)

    return struct(entries = entries, legacy_files = legacy_files, pycache_files = pycache_files)

def make_pyc_info(compiled, sources = [], deps = [], resolutions = []):
    """Merge this rule's own compiled bytecode with its dependencies'.

    Args:
        compiled: the struct returned by `compile_pycs` (or None).
        sources: list[File] — this rule's direct contribution to PyInfo.
        deps: Targets whose PycInfo (when present) is inherited.
        resolutions: additional Targets (virtual-dep resolutions) to inherit.

    Returns:
        PycInfo
    """
    transitive_entries = []
    transitive_legacy_files = []
    transitive_missing_sources = []
    transitive_pycache_files = []
    transitive_sourceless_files = []
    complete = True
    for dep in list(deps) + list(resolutions):
        if PycInfo in dep:
            dep_pyc = dep[PycInfo]
            transitive_entries.append(dep_pyc.entries)
            transitive_legacy_files.append(dep_pyc.legacy_files)
            transitive_missing_sources.append(dep_pyc.missing_sources)
            transitive_pycache_files.append(dep_pyc.pycache_files)
            transitive_sourceless_files.append(dep_pyc.sourceless_files)
            complete = complete and dep_pyc.complete
        elif has_py_info(dep) and PyWheelsInfo not in dep:
            complete = False

    direct_entries = compiled.entries if compiled else []
    compiled_sources = {entry.source.short_path: True for entry in direct_entries}
    missing_sources = []
    retained_sources = []
    for src in sources:
        if src.extension != "py":
            retained_sources.append(src)
        elif src.short_path not in compiled_sources:
            missing_sources.append(src)
    complete = complete and not missing_sources

    return PycInfo(
        complete = complete,
        direct_entries = direct_entries,
        entries = depset(
            direct = direct_entries,
            transitive = transitive_entries,
        ),
        legacy_files = depset(
            direct = compiled.legacy_files if compiled else [],
            transitive = transitive_legacy_files,
        ),
        missing_sources = depset(
            direct = missing_sources,
            transitive = transitive_missing_sources,
        ),
        pycache_files = depset(
            direct = compiled.pycache_files if compiled else [],
            transitive = transitive_pycache_files,
        ),
        sourceless_files = depset(
            direct = retained_sources + (compiled.legacy_files if compiled else []),
            transitive = transitive_sourceless_files,
        ),
    )

def _pyc_aspect_impl(target, ctx):
    # Srcs-less producers such as py_proto_library expose only transitive sources.
    if hasattr(ctx.rule.files, "srcs"):
        srcs = ctx.rule.files.srcs
    else:
        srcs = [
            src
            for src in get_py_info(target).transitive_sources.to_list()
            if src.owner.package == ctx.label.package and src.owner.workspace_name == ctx.label.workspace_name
        ]

    # Reuse bytecode outputs to avoid conflicting actions.
    existing = {}
    for action in target.actions:
        for out in action.outputs.to_list():
            if out.extension == "pyc":
                existing[out.short_path] = out
    return [make_pyc_info(
        compile_pycs(ctx, srcs, existing = existing),
        sources = srcs,
        deps = getattr(ctx.rule.attr, "deps", []),
    )]

pyc_aspect = aspect(
    doc = """Compiles bytecode for @rules_python targets reached through `deps`.

Applies only to rules advertising @rules_python's PyInfo, so it never visits
or propagates through rules_py targets. Bytecode rules_python already
compiled for a source is reused; the missing layout is compiled here.""",
    implementation = _pyc_aspect_impl,
    attr_aspects = ["deps"],
    attrs = PYC_ATTRS,
    required_providers = [[RulesPythonPyInfo]],
    toolchains = PYC_TOOLCHAINS,
    provides = [PycInfo],
)
