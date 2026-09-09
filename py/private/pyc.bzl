"""First-party Python bytecode compilation.

Libraries and venvs declare compile actions only below a launcher in a bytecode
mode, or under a global bytecode flag; source-only builds declare none.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//py/private:providers.bzl", "INACTIVE_PYC_INFO", "PycInfo")
load("//py/private:py_info_interop.bzl", "RulesPythonPyInfo", "get_py_info", "get_transitive_sources", "has_py_info")
load("//py/private:transitions.bzl", "PYC_FLAG")
load("//py/private/toolchain:pyc_compiler.bzl", "runtime_compiler")
load("//py/private/toolchain:types.bzl", "EXEC_TOOLS_TOOLCHAIN", "PYC_COMPILER_TOOLCHAIN", "PY_TOOLCHAIN")

PYC_MODES = ["off", "pycache", "sourceless"]

PycModeInfo = provider(
    doc = "Private: effective first-party bytecode mode of a runnable target.",
    fields = {"mode": "One of off, pycache, or sourceless."},
)

PYC_MODE_ATTRS = {
    "_pyc_flag": attr.label(
        default = PYC_FLAG,
        providers = [BuildSettingInfo],
    ),
}

PYC_ATTRS = PYC_MODE_ATTRS | {
    "_pyc_shards": attr.label(
        default = "//py:pyc_shards",
        providers = [BuildSettingInfo],
    ),
    "_pyc_compiler": attr.label(
        default = "//py/private:pyc_compile.py",
        allow_single_file = True,
    ),
}

# Terminals read only the flag, as the default for an unset `precompile` attribute.

# Compilation is optional until a pyc consumer requests complete bytecode.
PYC_TOOLCHAINS = [
    config_common.toolchain_type(PYC_COMPILER_TOOLCHAIN, mandatory = False),
    config_common.toolchain_type(EXEC_TOOLS_TOOLCHAIN, mandatory = False),
]

_PRERELEASE_ABBREVS = {"alpha": "a", "beta": "b", "candidate": "rc"}

def own_compile_sources(srcs_targets):
    """`srcs` entries that are file labels; files behind a rule target stay source.

    Args:
        srcs_targets: Targets of the rule's `srcs` attribute.

    Returns:
        list[File]
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

def bytecode_key(runtime):
    """Hashable identity of the bytecode a runtime loads.

    Args:
        runtime: PyRuntimeInfo.

    Returns:
        tuple, or None when the identity is unknown.
    """
    version_info = getattr(runtime, "interpreter_version_info", None)
    if version_info == None:
        return None

    pyc_tag = getattr(runtime, "pyc_tag", None)
    if pyc_tag:
        runtime_identity = ("pyc_tag", str(pyc_tag))
    elif getattr(runtime, "implementation_name", None):
        runtime_identity = ("implementation", str(runtime.implementation_name))
    else:
        return None
    if not str(runtime_identity[1]).startswith("cpython"):
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

    CPython final releases match on cache tag and major.minor; prereleases
    require an exact version match. Other implementations change bytecode
    between their own releases, so they only compile with themselves.
    """
    target_key = bytecode_key(target_runtime)
    return target_key != None and target_key == bytecode_key(exec_runtime)

def bytecode_conflicts(entry, other, mode):
    """Whether two configured entries for one source cannot share an image's bytecode path.

    Distinct `pycache` tags coexist beside their source; otherwise the bytecode
    must be interchangeable, and an unknown identity fails closed.
    """
    if mode == "pycache" and entry.pycache.basename != other.pycache.basename:
        return False
    return entry.bytecode_key == None or entry.bytecode_key != other.bytecode_key

def pycache_tag(runtime):
    """The runtime's declared PEP 3147 cache tag, or None; a guessed tag may never be read."""
    return getattr(runtime, "pyc_tag", None) or None

def _auto_shards(count):
    """Smallest power of two averaging at most 64 sources per shard; a target
    reshuffles only when its source count crosses a doubling boundary."""
    shards = 1
    for _ in range(count):
        if count <= shards * 64:
            break
        shards *= 2
    return shards

def _shard(path, shards):
    # String.hashCode leaves similar names in few low-bit patterns; mix before the modulus.
    h = hash(path) & 0xFFFFFFFF
    h = ((h ^ (h >> 16)) * 0x45D9F3B) & 0xFFFFFFFF
    return (h ^ (h >> 16)) % shards

def _compile_action(ctx, compiler, jobs, sourceless):
    compile_args = ctx.actions.args()
    compile_args.set_param_file_format("multiline")
    compile_args.use_param_file("@%s", use_always = True)
    if compiler.expected_version:
        compile_args.add("--expect-version", compiler.expected_version)
    if sourceless:
        compile_args.add("--sourceless")

    # A pseudo filename keeps sourceless tracebacks off unrelated cwd files; CPython
    # swaps in the real path when the source is present.
    for src, outputs in jobs:
        compile_args.add_all([src, outputs[0], "<{}>".format(src.short_path)])
    if len(jobs) == 1:
        progress = "Python precompiling {} into {}".format(jobs[0][0].short_path, ", ".join([out.short_path for out in jobs[0][1]]))
    else:
        progress = "Python precompiling {} sources for {}".format(len(jobs), ctx.label)
    ctx.actions.run(
        executable = compiler.tool.executable,
        toolchain = compiler.toolchain,
        arguments = [compiler.args, compile_args],
        execution_requirements = compiler.execution_requirements,
        inputs = [src for src, _ in jobs],
        tools = [compiler.tool.tools],
        outputs = [out for _, outputs in jobs for out in outputs],
        mnemonic = "PyCompile",
        progress_message = progress,
        env = {
            "PYTHONHASHSEED": "0",
            "PYTHONNOUSERSITE": "1",
            "PYTHONSAFEPATH": "1",
        },
    )

def compile_pycs(ctx, srcs, existing = {}, owned = True):
    """Compile this rule's own first-party sources to bytecode.

    Args:
        ctx: rule or aspect ctx carrying PYC_ATTRS and PYC_TOOLCHAINS.
        srcs: list[File] — the rule's direct sources.
        existing: dict[short_path, File] — bytecode the owning target already
            declares at the natural paths; taken instead of compiled.
        owned: whether `srcs` are this target's own; inferred sources shared
            by several targets are only compiled per source.

    Returns:
        struct(entries, pycache_files) of lists; empty lists
        when no bytecode-compatible compiler is available.
    """
    entries = []
    pycache_files = []

    target_toolchain = ctx.toolchains[PY_TOOLCHAIN]
    target_runtime = target_toolchain.py3_runtime if target_toolchain != None else None

    # Prefer the dedicated compiler, then a compatible exec runtime. The target
    # runtime never compiles: it may not run on the exec platform.
    pyc_compile_tool = None
    tool_toolchain = None
    if target_runtime != None:
        compiler = getattr(ctx.toolchains[PYC_COMPILER_TOOLCHAIN], "pyc_compiler", None)
        if compiler != None and (compiler.runtime == None or bytecode_compatible(compiler.runtime, target_runtime)):
            pyc_compile_tool, tool_toolchain = compiler, PYC_COMPILER_TOOLCHAIN
        else:
            exec_runtime = getattr(ctx.toolchains[EXEC_TOOLS_TOOLCHAIN], "exec_runtime", None)
            if getattr(exec_runtime, "interpreter", None) != None and bytecode_compatible(exec_runtime, target_runtime):
                pyc_compile_tool, tool_toolchain = runtime_compiler(exec_runtime, ctx.file._pyc_compiler), EXEC_TOOLS_TOOLCHAIN

    pyc_tag = pycache_tag(target_runtime)
    if target_runtime == None or pyc_compile_tool == None or pyc_tag == None:
        return struct(entries = entries, pycache_files = pycache_files)

    expected_version = _expected_version(target_runtime)

    # Per-source arguments go through the flagfile a worker receives per request.
    tool_args = ctx.actions.args()
    tool_args.add_all(pyc_compile_tool.arguments)

    # Bytecode embeds only the runfiles path, so one source compiles once across configurations.
    execution_requirements = {"supports-path-mapping": "1"}
    if getattr(pyc_compile_tool, "supports_workers", False):
        execution_requirements["supports-workers"] = "1"
        execution_requirements["requires-worker-protocol"] = "json"
    compiler = struct(
        tool = pyc_compile_tool,
        toolchain = tool_toolchain,
        args = tool_args,
        execution_requirements = execution_requirements,
        expected_version = expected_version,
    )

    shards = ctx.attr._pyc_shards[BuildSettingInfo].value
    if shards < -1:
        fail("--@aspect_rules_py//py:pyc_shards must be -1 (automatic), 0 (per source) or a shard count, got {}".format(shards))
    key = bytecode_key(target_runtime)
    jobs = []
    for src in srcs:
        if src.extension != "py":
            continue
        if src.owner.package != ctx.label.package or src.owner.workspace_name != ctx.label.workspace_name:
            continue
        stem = src.basename[:-3]
        pycache_basename = "{}.{}.pyc".format(stem, pyc_tag)
        pyc = None
        pycache = None
        if existing:
            directory = src.short_path[:-len(src.basename)]
            pyc = existing.get(directory + stem + ".pyc")
            pycache = existing.get(directory + "__pycache__/" + pycache_basename)

        outputs = []
        if pycache == None:
            pycache = ctx.actions.declare_file("__pycache__/{}".format(pycache_basename), sibling = src)
            outputs.append(pycache)
        if pyc == None:
            pyc = ctx.actions.declare_file(stem + ".pyc", sibling = src)
            outputs.append(pyc)
        if outputs:
            jobs.append((src, outputs))
        entries.append(struct(source = src, pyc = pyc, pycache = pycache, bytecode_key = key))
        pycache_files.append(pycache)

    # Per-source actions stay shareable across targets; path-hash shards keep other
    # shards' keys stable when a source is added.
    if not owned:
        shards = 0
    elif shards == -1:
        shards = _auto_shards(len(jobs))
    groups = {}
    for job in jobs:
        group_key = (_shard(job[0].short_path, shards) if shards else len(groups), len(job[1]))
        groups.setdefault(group_key, []).append(job)
    for (_, outputs), group in groups.items():
        _compile_action(ctx, compiler, group, outputs == 2)

    return struct(entries = entries, pycache_files = pycache_files)

def make_pyc_info(compiled, sources = [], deps = [], resolutions = [], conflicts = [], source_retained = False):
    """Merge this rule's own compiled bytecode with its dependencies'.

    Args:
        compiled: the struct returned by `compile_pycs` (or None).
        sources: list[File] — this rule's direct contribution to PyInfo.
        deps: Targets whose PycInfo (when present) is inherited.
        resolutions: additional Targets (virtual-dep resolutions) to inherit.
        conflicts: list[string] — reasons this target's bytecode cannot serve level-0 modes.
        source_retained: whether the target ships its own sources regardless of
            mode, so a sourceless launcher needs the `__pycache__` layout too.

    Returns:
        PycInfo
    """
    transitive_conflicts = []
    transitive_entries = []
    transitive_missing_sources = []
    transitive_pycache_files = []
    transitive_sourceless_files = []
    complete = True
    for dep in list(deps) + list(resolutions):
        if PycInfo in dep:
            dep_pyc = dep[PycInfo]
            transitive_conflicts.append(dep_pyc.conflicts)
            transitive_entries.append(dep_pyc.entries)
            transitive_missing_sources.append(dep_pyc.missing_sources)
            transitive_pycache_files.append(dep_pyc.pycache_files)
            transitive_sourceless_files.append(dep_pyc.sourceless_files)
            complete = complete and dep_pyc.complete
        elif has_py_info(dep):
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
        conflicts = depset(direct = conflicts, transitive = transitive_conflicts),
        direct_entries = direct_entries,
        entries = depset(
            direct = direct_entries,
            transitive = transitive_entries,
        ),
        missing_sources = depset(
            direct = missing_sources,
            transitive = transitive_missing_sources,
        ),
        pycache_files = depset(
            direct = compiled.pycache_files if compiled else [],
            transitive = transitive_pycache_files,
        ),
        transitive_pycache_files = depset(transitive = transitive_pycache_files),
        sourceless_files = depset(
            direct = retained_sources + [entry.pyc for entry in direct_entries] + ([entry.pycache for entry in direct_entries] if source_retained else []),
            transitive = transitive_sourceless_files,
        ),
    )

def _same_package(f, label):
    return f.owner.package == label.package and f.owner.workspace_name == label.workspace_name

def _precompile_active(ctx):
    return ctx.attr._pyc_flag[BuildSettingInfo].value != "off"

def target_pyc_info(ctx):
    """PycInfo for a rules_py target's own srcs and deps, compiled only below a bytecode launcher."""
    if not _precompile_active(ctx):
        return INACTIVE_PYC_INFO
    return make_pyc_info(
        compile_pycs(ctx, own_compile_sources(ctx.attr.srcs)),
        sources = ctx.files.srcs,
        deps = ctx.attr.deps,
        resolutions = getattr(ctx.attr, "resolutions", {}).values(),
    )

def _pyc_aspect_impl(target, ctx):
    if not _precompile_active(ctx):
        return [INACTIVE_PYC_INFO]

    # Reuse bytecode the target's own actions declare at the natural paths.
    existing = {}
    for action in target.actions:
        for out in action.outputs.to_list():
            if out.extension == "pyc":
                existing[out.short_path] = out

    # Srcs-less forwarders (e.g. py_proto_library) compile only same-package transitive sources.
    owned = hasattr(ctx.rule.files, "srcs")
    if owned:
        # pip hub wheels are third-party and run from source.
        srcs = [src for src in ctx.rule.files.srcs if "/site-packages/" not in src.short_path]
    else:
        info = get_py_info(target)
        srcs = [src for src in get_transitive_sources(target).to_list() if _same_package(src, ctx.label)]
        for f in depset(transitive = [
            getattr(info, "transitive_pyc_files", depset()),
            getattr(info, "transitive_implicit_pyc_files", depset()),
        ]).to_list():
            if _same_package(f, ctx.label):
                existing[f.short_path] = f

    # rules_python writes optimized bytecode to the level-0 path, which a launcher would load.
    conflicts = []
    optimize_level = getattr(ctx.rule.attr, "precompile_optimize_level", 0)
    if existing and optimize_level:
        conflicts.append("{} precompiles at precompile_optimize_level = {}; bytecode modes need level 0".format(target.label, optimize_level))
        srcs = []

    # rules_python keeps its sources in runfiles, so sourceless launchers need __pycache__ too.
    return [make_pyc_info(
        compile_pycs(ctx, srcs, existing = existing, owned = owned),
        sources = srcs,
        deps = getattr(ctx.rule.attr, "deps", []),
        conflicts = conflicts,
        source_retained = True,
    )]

pyc_aspect = aspect(
    doc = """Compiles bytecode for @rules_python targets reached through `deps`,
reusing any layout rules_python already compiled.""",
    implementation = _pyc_aspect_impl,
    attr_aspects = ["deps"],
    attrs = PYC_ATTRS,
    required_providers = [[RulesPythonPyInfo]],
    toolchains = [config_common.toolchain_type(PY_TOOLCHAIN, mandatory = False)] + PYC_TOOLCHAINS,
    provides = [PycInfo],
)
