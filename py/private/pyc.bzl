"""First-party Python bytecode compilation.

Libraries and venvs always declare the compile actions; only launchers in a
bytecode mode request their outputs.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//py/private:providers.bzl", "PyWheelsInfo")
load("//py/private:py_info_interop.bzl", "RulesPythonPyInfo", "get_py_info", "has_py_info")
load("//py/private:transitions.bzl", "PYC_FLAG")
load("//py/private/toolchain:types.bzl", "EXEC_TOOLS_TOOLCHAIN", "PYC_COMPILER_TOOLCHAIN", "PY_TOOLCHAIN")

PYC_MODES = ["source", "pyc", "pyc_only"]

PycInfo = provider(
    doc = "Private: first-party Python bytecode artifacts.",
    fields = {
        "complete": "bool — whether every transitive Python source has a bytecode entry.",
        "conflicts": "depset[string] — dependencies whose own bytecode at the natural paths is unusable at level 0.",
        "direct_entries": "list[struct(source, pyc, pycache)] — bytecode mappings declared directly by this target.",
        "entries": "depset[struct(source, pyc, pycache)] — transitive bytecode mappings; pyc is the colocated sourceless layout, byte-identical to pycache.",
        "sourceless_pyc_files": "depset[File] — colocated sourceless .pyc files.",
        "missing_sources": "depset[File] — Python sources without bytecode entries.",
        "pycache_files": "depset[File] — PEP 3147 __pycache__ files for source-retaining mode.",
        "transitive_pycache_files": "depset[File] — pycache_files of dependencies only, without this target's direct entries.",
        "sourceless_files": "depset[File] — colocated .pyc files plus non-Python source artifacts retained by pyc_only.",
    },
)

PycModeInfo = provider(
    doc = "Private: effective first-party bytecode mode of a runnable target.",
    fields = {"mode": "One of source, pyc, or pyc_only."},
)

PYC_ATTRS = {
    "_pyc_shards": attr.label(
        default = "//py:pyc_shards",
        providers = [BuildSettingInfo],
    ),
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
    """The runtime's declared PEP 3147 cache tag, or None; a guessed tag may never be read."""
    return getattr(runtime, "pyc_tag", None) or None

def _auto_shards(count):
    """Smallest power of two keeping shards at or under 64 sources, so a target
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
    for src, outputs in jobs:
        compile_args.add_all([src, outputs[0], src.short_path])
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

def compile_pycs(ctx, srcs, existing = {}):
    """Compile this rule's own first-party sources to bytecode.

    Args:
        ctx: rule or aspect ctx carrying PYC_ATTRS and PYC_TOOLCHAINS.
        srcs: list[File] — the rule's direct sources.
        existing: dict[short_path, File] — bytecode the owning target already
            declares at the natural paths; taken instead of compiled.

    Returns:
        struct(entries, sourceless_pyc_files, pycache_files) of lists; empty lists
        when no bytecode-compatible compiler is available.
    """
    entries = []
    sourceless_pyc_files = []
    pycache_files = []

    target_toolchain = ctx.toolchains[PY_TOOLCHAIN]
    target_runtime = target_toolchain.py3_runtime if target_toolchain != None else None

    # Prefer the dedicated compiler, then compatible exec or target runtimes.
    pyc_compile_tool = None
    tool_toolchain = PYC_COMPILER_TOOLCHAIN
    compiler_toolchain = ctx.toolchains[PYC_COMPILER_TOOLCHAIN]
    compiler = getattr(compiler_toolchain, "pyc_compiler", None) if compiler_toolchain != None else None
    if target_runtime != None and compiler != None and (compiler.runtime == None or bytecode_compatible(compiler.runtime, target_runtime)):
        pyc_compile_tool = compiler
    elif target_runtime != None:
        exec_toolchain = ctx.toolchains[EXEC_TOOLS_TOOLCHAIN]
        exec_runtime = getattr(exec_toolchain, "exec_runtime", None) if exec_toolchain != None else None
        compile_runtime = None
        if exec_runtime != None and getattr(exec_runtime, "interpreter", None) != None and bytecode_compatible(exec_runtime, target_runtime):
            compile_runtime = exec_runtime
            tool_toolchain = EXEC_TOOLS_TOOLCHAIN
        elif target_runtime.interpreter != None:
            compile_runtime = target_runtime
            tool_toolchain = PY_TOOLCHAIN
        if compile_runtime != None:
            pyc_compile_tool = struct(
                executable = compile_runtime.interpreter,
                arguments = ["-S", "-s", "-B", ctx.file._pyc_compiler],
                tools = depset(
                    [compile_runtime.interpreter, ctx.file._pyc_compiler],
                    transitive = [compile_runtime.files],
                ),
                supports_workers = True,
            )

    pyc_tag = pycache_tag(target_runtime)
    if target_runtime == None or pyc_compile_tool == None or pyc_tag == None:
        return struct(entries = entries, sourceless_pyc_files = sourceless_pyc_files, pycache_files = pycache_files)

    expected_version = _expected_version(target_runtime)

    # Startup arguments stay on the command line; per-source arguments go
    # through a flagfile so a persistent worker receives them per request.
    tool_args = ctx.actions.args()
    tool_args.add_all(pyc_compile_tool.arguments)

    # Every path reaches the compiler as a File and the bytecode embeds only the
    # runfiles path, so one source compiles once across configurations.
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
        entries.append(struct(source = src, pyc = pyc, pycache = pycache))
        sourceless_pyc_files.append(pyc)
        pycache_files.append(pycache)

    # Both layouts unless rules_python already built __pycache__ for the target.
    sourceless = not existing

    # Per-source actions stay identical when targets share a source. Sharding
    # by path hash keeps every other shard's action key stable when a source is added.
    if shards == -1:
        shards = _auto_shards(len(jobs))
    groups = {}
    for job in jobs:
        key = _shard(job[0].short_path, shards) if shards else len(groups)
        groups.setdefault(key, []).append(job)
    for group in groups.values():
        _compile_action(ctx, compiler, group, sourceless)

    return struct(entries = entries, sourceless_pyc_files = sourceless_pyc_files, pycache_files = pycache_files)

def make_pyc_info(compiled, sources = [], deps = [], resolutions = [], conflicts = []):
    """Merge this rule's own compiled bytecode with its dependencies'.

    Args:
        compiled: the struct returned by `compile_pycs` (or None).
        sources: list[File] — this rule's direct contribution to PyInfo.
        deps: Targets whose PycInfo (when present) is inherited.
        resolutions: additional Targets (virtual-dep resolutions) to inherit.
        conflicts: list[string] — reasons this target's bytecode cannot serve level-0 modes.

    Returns:
        PycInfo
    """
    transitive_conflicts = []
    transitive_entries = []
    transitive_sourceless_pyc_files = []
    transitive_missing_sources = []
    transitive_pycache_files = []
    transitive_sourceless_files = []
    complete = True
    for dep in list(deps) + list(resolutions):
        if PycInfo in dep:
            dep_pyc = dep[PycInfo]
            transitive_conflicts.append(dep_pyc.conflicts)
            transitive_entries.append(dep_pyc.entries)
            transitive_sourceless_pyc_files.append(dep_pyc.sourceless_pyc_files)
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
        conflicts = depset(direct = conflicts, transitive = transitive_conflicts),
        direct_entries = direct_entries,
        entries = depset(
            direct = direct_entries,
            transitive = transitive_entries,
        ),
        sourceless_pyc_files = depset(
            direct = compiled.sourceless_pyc_files if compiled else [],
            transitive = transitive_sourceless_pyc_files,
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
            direct = retained_sources + (compiled.sourceless_pyc_files if compiled else []),
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

    # Reuse bytecode this target already declares at the natural paths. Only its
    # own actions are scanned; the provider's transitive set would flatten per producer.
    existing = {}
    for action in target.actions:
        for out in action.outputs.to_list():
            if out.extension == "pyc":
                existing[out.short_path] = out

    # rules_python writes optimized bytecode to the level-0 natural path, where
    # the launcher's interpreter would load it in place of level-0 code.
    conflicts = []
    optimize_level = getattr(ctx.rule.attr, "precompile_optimize_level", 0)
    if existing and optimize_level:
        conflicts.append("{} precompiles at precompile_optimize_level = {}; bytecode modes need level 0".format(target.label, optimize_level))
        srcs = []
    return [make_pyc_info(
        compile_pycs(ctx, srcs, existing = existing),
        sources = srcs,
        deps = getattr(ctx.rule.attr, "deps", []),
        conflicts = conflicts,
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
