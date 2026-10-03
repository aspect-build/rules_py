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

# `-X` option a sourceless launcher passes so its venv can tell it apart from `pycache`.
SOURCELESS_XOPTION = "aspect_rules_py_sourceless"

PycModeInfo = provider(
    doc = "Private: effective first-party bytecode mode of a runnable target.",
    fields = {
        "main": "str — short_path of the launcher's main, whose own bytecode CPython never reads under pycache.",
        "mode": "One of off, pycache, or sourceless.",
    },
)

# Terminals read only the flag, as the default for an unset `precompile` attribute.
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
    "_pyc_invalidation_mode": attr.label(
        default = "//py:pyc_invalidation_mode",
        providers = [BuildSettingInfo],
    ),
    "_pyc_compiler": attr.label(
        default = "//py/private:pyc_compile.py",
        allow_single_file = True,
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

def expected_version(runtime):
    """Version string the compiler must match, or None when unknown.

    Args:
        runtime: PyRuntimeInfo of the target.

    Returns:
        str, formatted as `pyc_compile.py --expect-version` parses it, or None.
    """
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
    is_cpython = runtime_identity[1].startswith("cpython")

    # Other implementations report only the language version, so only one interpreter artifact vouches for its own bytecode.
    interpreter = None
    if not is_cpython:
        interpreter = getattr(getattr(runtime, "interpreter", None), "path", None)
        if not interpreter:
            return None

    key = [
        runtime_identity,
        str(getattr(version_info, "major", None)),
        str(getattr(version_info, "minor", None)),
    ]
    if interpreter:
        key.append(("interpreter", interpreter))
    releaselevel = getattr(version_info, "releaselevel", None) or "final"
    if not is_cpython or releaselevel != "final":
        key += [
            str(getattr(version_info, "micro", None) or 0),
            releaselevel,
            str(getattr(version_info, "serial", None) or 0),
        ]
    return tuple(key)

def bytecode_compatible(exec_runtime, target_runtime):
    """Whether `exec_runtime` emits bytecode loadable by `target_runtime`.

    CPython final releases match on cache tag and major.minor; prereleases
    require an exact version match. Other implementations require the same
    interpreter artifact and version.
    """
    target_key = bytecode_key(target_runtime)
    return target_key != None and target_key == bytecode_key(exec_runtime)

def bytecode_conflicts(entry, other, mode):
    """Whether two configured entries for one source cannot share an image's bytecode path.

    Distinct `pycache` tags coexist beside their source; otherwise the bytecode
    must be interchangeable, and an unknown identity fails closed.
    """
    if mode == "pycache" and entry.pycache_path.rpartition("/")[2] != other.pycache_path.rpartition("/")[2]:
        return False
    return entry.bytecode_key == None or entry.bytecode_key != other.bytecode_key

def pycache_tag(runtime):
    """The runtime's declared PEP 3147 cache tag, or None; a guessed tag may never be read."""
    return getattr(runtime, "pyc_tag", None) or None

def auto_shards(count):
    """Smallest power of two averaging at most 64 sources per shard.

    A target reshuffles only when its source count crosses a doubling boundary.

    Args:
        count: number of sources to compile.

    Returns:
        int
    """
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

def _package_prefix(label):
    """The short_path prefix of files in `label`'s package."""
    prefix = "../{}/".format(label.workspace_name) if label.workspace_name else ""
    return prefix + label.package + "/" if label.package else prefix

def layout_runfiles(ctx, mappings, files = [], transitive = []):
    """Runfiles placing bytecode at its natural paths.

    Args:
        ctx: rule or aspect ctx.
        mappings: list[(short path, File)] — bytecode and where CPython reads it,
            in `File.short_path` form (`../<repo>/...` outside the main repository).
        files: list[File] — other files kept at their own paths.
        transitive: list[runfiles] — dependency layouts to merge.

    Returns:
        runfiles
    """

    # Files already at their natural path are plain runfiles, which win over symlinks there.
    plain = list(files)
    symlinks = {}
    root_symlinks = {}
    for path, f in mappings:
        if f.short_path == path:
            plain.append(f)
        elif path.startswith("../"):
            root_symlinks[path[len("../"):]] = f
        else:
            symlinks[path] = f
    return ctx.runfiles(files = plain, symlinks = symlinks, root_symlinks = root_symlinks).merge_all([r for r in transitive if r != None])

def _compile_action(ctx, compiler, jobs):
    compile_args = ctx.actions.args()
    compile_args.set_param_file_format("multiline")
    compile_args.use_param_file("@%s", use_always = True)
    if compiler.expected_version:
        compile_args.add("--expect-version", compiler.expected_version)
    if compiler.checked_hash:
        compile_args.add("--checked-hash")

    # A pseudo filename keeps sourceless tracebacks off unrelated cwd files; CPython
    # swaps in the real path when the source is present.
    for src, out in jobs:
        compile_args.add_all([src, out, "<{}>".format(src.short_path)])
    if len(jobs) == 1:
        progress = "Python precompiling {} into {}".format(jobs[0][0].short_path, jobs[0][1].short_path)
    else:
        progress = "Python precompiling {} sources for {}".format(len(jobs), ctx.label)
    ctx.actions.run(
        executable = compiler.tool.executable,
        toolchain = compiler.toolchain,
        arguments = [compiler.args, compile_args],
        execution_requirements = compiler.execution_requirements,
        inputs = [src for src, _ in jobs],
        tools = [compiler.tool.tools],
        outputs = [out for _, out in jobs],
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

    Each source compiles once, into a directory of this target's own, so several
    targets listing one source never declare the same output. Runfiles place the
    result at the natural paths; see `make_pyc_info`.

    Args:
        ctx: rule or aspect ctx carrying PYC_ATTRS and PYC_TOOLCHAINS.
        srcs: list[File] — the rule's direct sources.
        existing: dict[short_path, File] — bytecode the owning target already
            declares at the natural paths; taken instead of compiled.

    Returns:
        struct(entries) — empty when no bytecode-compatible compiler is available.
    """
    entries = []

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
        return struct(entries = entries)

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
        expected_version = expected_version(target_runtime),
        checked_hash = ctx.attr._pyc_invalidation_mode[BuildSettingInfo].value == "checked-hash",
    )

    shards = ctx.attr._pyc_shards[BuildSettingInfo].value
    if shards < -1:
        fail("--@aspect_rules_py//py:pyc_shards must be -1 (automatic), 0 (per source) or a shard count, got {}".format(shards))
    key = bytecode_key(target_runtime)
    package_prefix = _package_prefix(ctx.label)
    jobs = []
    for src in srcs:
        if src.extension != "py":
            continue
        if src.owner.package != ctx.label.package or src.owner.workspace_name != ctx.label.workspace_name:
            continue
        stem = src.short_path[:-len(".py")]
        directory = src.short_path[:-len(src.basename)]
        pyc_short_path = stem + ".pyc"
        pycache_short_path = "{}__pycache__/{}.{}.pyc".format(directory, src.basename[:-len(".py")], pyc_tag)
        pyc = existing.get(pyc_short_path)
        pycache = existing.get(pycache_short_path)
        if pyc == None or pycache == None:
            compiled = ctx.actions.declare_file("_{}.pyc/{}.pyc".format(ctx.label.name, stem[len(package_prefix):]))
            jobs.append((src, compiled))
            pyc = pyc or compiled
            pycache = pycache or compiled
        entries.append(struct(
            source = src,
            pyc = pyc,
            pyc_path = pyc_short_path,
            pycache = pycache,
            pycache_path = pycache_short_path,
            bytecode_key = key,
        ))

    # Path-hash shards keep other shards' keys stable when a source is added.
    if shards == -1:
        shards = auto_shards(len(jobs))
    if shards:
        sharded = {}
        for job in jobs:
            sharded.setdefault(_shard(job[0].short_path, shards), []).append(job)
        groups = sharded.values()
    else:
        groups = [[job] for job in jobs]
    for group in groups:
        _compile_action(ctx, compiler, group)

    return struct(entries = entries)

def make_pyc_info(ctx, compiled, sources = [], deps = [], conflicts = [], source_retained = False, validations = []):
    """Merge this rule's own compiled bytecode with its dependencies'.

    Args:
        ctx: rule or aspect ctx.
        compiled: the struct returned by `compile_pycs` (or None).
        sources: list[File] — this rule's direct contribution to PyInfo.
        deps: Targets whose PycInfo (when present) is inherited.
        conflicts: list[string] — reasons this target's bytecode cannot serve level-0 modes.
        source_retained: whether the target ships its own sources regardless of
            mode, so a sourceless launcher needs the `__pycache__` layout too.
        validations: list[File] — validation outputs a launcher must build.

    Returns:
        PycInfo
    """
    transitive_conflicts = []
    transitive_entries = []
    transitive_missing_sources = []
    transitive_pycache_runfiles = []
    transitive_sourceless_runfiles = []
    transitive_validations = []
    complete = True
    for dep in deps:
        if PycInfo in dep:
            dep_pyc = dep[PycInfo]
            transitive_conflicts.append(dep_pyc.conflicts)
            transitive_entries.append(dep_pyc.entries)
            transitive_missing_sources.append(dep_pyc.missing_sources)
            transitive_pycache_runfiles.append(dep_pyc.pycache_runfiles)
            transitive_sourceless_runfiles.append(dep_pyc.sourceless_runfiles)
            transitive_validations.append(dep_pyc.validations)
            complete = complete and dep_pyc.complete
        elif has_py_info(dep):
            complete = False

    direct_entries = compiled.entries if compiled else []
    compiled_sources = {entry.source.short_path: True for entry in direct_entries}
    missing_sources = []
    retained_sources = []
    for src in sources:
        # Type stubs never enter runfiles; other sidecars ship as they are.
        if src.extension == "pyi":
            continue
        elif src.extension != "py":
            retained_sources.append(src)
        elif src.short_path not in compiled_sources:
            missing_sources.append(src)
    complete = complete and not missing_sources

    pycache_mappings = [(entry.pycache_path, entry.pycache) for entry in direct_entries]
    sourceless_mappings = [(entry.pyc_path, entry.pyc) for entry in direct_entries]
    if source_retained:
        sourceless_mappings += pycache_mappings
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
        pycache_runfiles = layout_runfiles(ctx, pycache_mappings, transitive = transitive_pycache_runfiles),
        transitive_pycache_runfiles = layout_runfiles(ctx, [], transitive = transitive_pycache_runfiles),
        sourceless_runfiles = layout_runfiles(ctx, sourceless_mappings, retained_sources, transitive_sourceless_runfiles),
        validations = depset(direct = validations, transitive = transitive_validations),
    )

def _same_package(f, label):
    return f.owner.package == label.package and f.owner.workspace_name == label.workspace_name

def _precompile_active(ctx):
    return ctx.attr._pyc_flag[BuildSettingInfo].value != "off"

def target_pyc_info(ctx):
    """PycInfo for a rules_py target's own srcs and deps, compiled only below a bytecode launcher.

    Args:
        ctx: rule ctx carrying PYC_ATTRS and PYC_TOOLCHAINS, with `srcs` and `deps`.

    Returns:
        PycInfo
    """
    deps = ctx.attr.deps + getattr(ctx.attr, "resolutions", {}).values()

    # A launcher is not code: its runfiles keep its own mode's files, so no consumer can package it as a library.
    for dep in deps:
        if PycModeInfo in dep:
            fail("{}: {} is a py_binary or py_test, which is not supported in deps; depend on its py_library instead".format(ctx.label, dep.label))
    if not _precompile_active(ctx):
        return INACTIVE_PYC_INFO
    return make_pyc_info(
        ctx,
        compile_pycs(ctx, own_compile_sources(ctx.attr.srcs)),
        sources = ctx.files.srcs,
        deps = deps,
    )

def _check_reused_bytecode(ctx, reused):
    """A validation stamp proving bytecode another ruleset produced is checked-hash, or None without an exec interpreter."""
    exec_runtime = getattr(ctx.toolchains[EXEC_TOOLS_TOOLCHAIN], "exec_runtime", None)
    if getattr(exec_runtime, "interpreter", None) == None:
        return None
    stamp = ctx.actions.declare_file(ctx.label.name + ".pyc_check")
    interpreter_args = ctx.actions.args()
    interpreter_args.add_all(["-S", "-s", "-B", ctx.file._pyc_check])

    # A reusing target can list more bytecode than a command line holds.
    check_args = ctx.actions.args()
    check_args.set_param_file_format("multiline")
    check_args.use_param_file("@%s", use_always = True)
    check_args.add(stamp)
    check_args.add_all(reused)
    ctx.actions.run(
        executable = exec_runtime.interpreter,
        arguments = [interpreter_args, check_args],
        inputs = reused + [ctx.file._pyc_check],
        tools = exec_runtime.files,
        outputs = [stamp],
        mnemonic = "PyCheckBytecode",
        progress_message = "Checking reused bytecode of %{label}",
        toolchain = EXEC_TOOLS_TOOLCHAIN,
    )
    return stamp

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

        # O(closure) per wrapper; `PyInfo.direct_original_sources` would make it O(direct),
        # but protobuf's py_proto_library (34.0 through 36.2) leaves it empty.
        srcs = [src for src in get_transitive_sources(target).to_list() if _same_package(src, ctx.label)]
        for f in depset(transitive = [
            getattr(info, "transitive_pyc_files", depset()),
            getattr(info, "transitive_implicit_pyc_files", depset()),
        ]).to_list():
            if _same_package(f, ctx.label):
                existing[f.short_path] = f

    # rules_python writes optimized bytecode to the level-0 paths, whichever layout it keeps.
    conflicts = []
    optimize_level = getattr(ctx.rule.attr, "precompile_optimize_level", 0)
    if existing and optimize_level:
        conflicts.append("{} precompiles at precompile_optimize_level = {}; bytecode modes need level 0, so set it to 0 or disable its precompilation".format(target.label, optimize_level))
        srcs = []

    compiled = compile_pycs(ctx, srcs, existing = existing)

    # Reused bytecode keeps its producer's invalidation mode; checked-hash verifies the headers themselves.
    # Only `__pycache__` is read beside a source; a colocated `.pyc` runs only without one, so it has nothing to check.
    validations = []
    reused = [entry.pycache for entry in compiled.entries if existing.get(entry.pycache.short_path) == entry.pycache]
    if reused and ctx.attr._pyc_invalidation_mode[BuildSettingInfo].value == "checked-hash":
        stamp = _check_reused_bytecode(ctx, reused)
        if stamp == None:
            conflicts.append("{} reuses rules_python bytecode that checked-hash cannot verify without an exec interpreter".format(target.label))
        else:
            validations.append(stamp)

    # rules_python keeps its sources in runfiles, so sourceless launchers need __pycache__ too.
    return [make_pyc_info(
        ctx,
        compiled,
        sources = srcs,
        deps = getattr(ctx.rule.attr, "deps", []),
        conflicts = conflicts,
        source_retained = True,
        validations = validations,
    )]

pyc_aspect = aspect(
    doc = """Compiles bytecode for @rules_python targets reached through `deps`,
reusing any layout rules_python already compiled.""",
    implementation = _pyc_aspect_impl,
    attr_aspects = ["deps"],
    attrs = PYC_ATTRS | {
        "_pyc_check": attr.label(
            default = "//py/private:pyc_check.py",
            allow_single_file = True,
        ),
    },
    required_providers = [[RulesPythonPyInfo]],
    toolchains = [config_common.toolchain_type(PY_TOOLCHAIN, mandatory = False)] + PYC_TOOLCHAINS,
    provides = [PycInfo],
)
