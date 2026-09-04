"""First-party Python bytecode compilation.

This intentionally does not extend ``PyInfo``.  ``PyInfo`` remains the
source/import graph contract; ``FirstPartyPycInfo`` is a target-runtime-
specific view of that graph, produced unconditionally ("auto") by the
``py_library`` / ``py_venv`` rules themselves.  Declared compile actions
only execute when a consumer requests the bytecode, so the real opt-in
lives at the terminal edges (``py_binary`` / ``py_test`` / ``py_venv_exec``
/ ``py_image_layer``) via their ``pyc`` attribute and the ``//py:pyc``
flag.  Because nothing below the terminal is configured on the mode, every
launcher sharing a configured ``py_library`` shares its compile actions.
"""

load("//py/private:py_info_interop.bzl", "has_py_info")
load("//py/private/toolchain:types.bzl", "EXEC_TOOLS_TOOLCHAIN", "PY_TOOLCHAIN")

FirstPartyPycInfo = provider(
    doc = "Private: first-party Python bytecode artifacts.",
    fields = {
        "entries": "depset[struct(source, pyc, pycache)] — transitive bytecode mappings; pycache is None when the runtime has no cache tag.",
        "legacy_files": "depset[File] — colocated sourceless .pyc files.",
        "pycache_files": "depset[File] — PEP 3147 __pycache__ files for source-retaining mode.",
    },
)

FirstPartyPycModeInfo = provider(
    doc = "Private: effective first-party bytecode mode of a runnable target.",
    fields = {"mode": "One of source, pyc, or pyc_only."},
)

# Shared implicit attrs for rules that compile first-party bytecode.
PYC_ATTRS = {
    # Fallback compiler script for toolchains carrying no pyc_compile_tool.
    "_pyc_compiler": attr.label(
        default = "//py/private:pyc_compile.py",
        allow_single_file = True,
    ),
}

# Optional so targets keep analyzing in setups that never registered a Python
# (or rules_py exec-tools) toolchain; compilation is then skipped and the
# pyc_only terminal reports the affected sources as missing bytecode.
PYC_TOOLCHAINS = [
    config_common.toolchain_type(PY_TOOLCHAIN, mandatory = False),
    config_common.toolchain_type(EXEC_TOOLS_TOOLCHAIN, mandatory = False),
]

_PRERELEASE_ABBREVS = {"alpha": "a", "beta": "b", "candidate": "rc"}

def own_compile_sources(srcs_targets):
    """Files this target compiles: srcs entries that are plain file labels.

    Rule targets in `srcs` are opaque to bytecode compilation: a Python rule
    compiles its own srcs, and `.py` files reached through another rule's
    DefaultInfo (filegroup, genrule, py_library-in-srcs) are not first-party
    bytecode candidates — they stay in source form, and the pyc_only terminal
    reports them as missing. Both source files and generated files count when
    listed by their own file label.
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
        # A source file's owner is its own label.
        return owner == label

    # A generated file's owner is the rule that declares it, so an owner
    # matching `label` means the generating rule itself was listed. The
    # file's own label (when listed directly) shares the owner's package and
    # names the file's package-relative path; a rule label can never collide
    # with the path of one of its own outputs, so a path match identifies an
    # output-file target.
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
    parts = [version_info.major, version_info.minor]
    micro = getattr(version_info, "micro", None)
    if micro != None:
        parts.append(micro)
    expected = ".".join([str(p) for p in parts])
    releaselevel = getattr(version_info, "releaselevel", None)
    if micro != None and releaselevel and releaselevel != "final":
        serial = getattr(version_info, "serial", None)
        expected += _PRERELEASE_ABBREVS.get(releaselevel, releaselevel) + str(serial if serial != None else 0)
    return expected

def _bytecode_key(runtime):
    version_info = getattr(runtime, "interpreter_version_info", None)
    if version_info == None:
        return None

    # A cache tag is the strongest available runtime-format identity. Fall
    # back to the implementation name for runtimes that do not expose one;
    # if neither is known, using a different interpreter is not safe.
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
        # Bytecode magic may change between prereleases of one feature
        # release; a prerelease never matches a final or another prerelease.
        key += [
            str(getattr(version_info, "micro", None)),
            releaselevel,
            str(getattr(version_info, "serial", None)),
        ]
    return tuple(key)

def bytecode_compatible(exec_runtime, target_runtime):
    """Whether `exec_runtime` emits bytecode loadable by `target_runtime`.

    Bytecode is platform-independent and its magic is stable within a final
    feature release, so a final exec interpreter is usable iff it shares the
    implementation/cache tag and major.minor with the target runtime;
    prereleases require an exact version match. Needed because exec-tools
    resolution gates on major.minor only and carries an ungated any-version
    fallback.
    """
    target_key = _bytecode_key(target_runtime)
    return target_key != None and target_key == _bytecode_key(exec_runtime)

def pycache_tag(runtime):
    """Return the runtime's PEP 3147 cache tag, when one can be determined."""
    tag = getattr(runtime, "pyc_tag", None)
    if tag:
        return tag
    implementation_name = getattr(runtime, "implementation_name", None)
    version = getattr(runtime, "interpreter_version_info", None)
    if not implementation_name or version == None:
        return None
    return "{}-{}{}".format(implementation_name, version.major, version.minor)

def compile_pycs(ctx, srcs):
    """Compile this rule's own first-party sources to bytecode.

    Only sources directly owned by this target's package are compiled — a
    ``sibling=`` declaration (which keeps the bytecode's natural runfiles
    location next to its source) is only permitted for files of the declaring
    package. Foreign sources are expected to be compiled by their own owning
    target; the pyc_only terminal validates that none remain.

    Args:
        ctx: rule ctx carrying PYC_ATTRS and PYC_TOOLCHAINS.
        srcs: list[File] — the rule's direct sources.

    Returns:
        struct(entries, legacy_files, pycache_files) of lists; empty lists
        when no bytecode-compatible compiler is available.
    """
    entries = []
    legacy_files = []
    pycache_files = []

    target_toolchain = ctx.toolchains[PY_TOOLCHAIN]
    target_runtime = target_toolchain.py3_runtime if target_toolchain != None else None

    # Compiler preference: a custom `pyc_compile_tool` wins; then the
    # exec-tools interpreter when bytecode-compatible with the target runtime
    # (enables cross builds); then the target runtime's own interpreter
    # (native builds and non-rules_py toolchains, where the target interpreter
    # must be runnable on the exec host). `--expect-version` backstops all
    # three at execution time.
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
            )

    if target_runtime == None or pyc_compile_tool == None:
        return struct(entries = entries, legacy_files = legacy_files, pycache_files = pycache_files)

    # Verified by the compiler so a mismatched `pyc_compile_tool` (or a
    # fallback-resolved exec-tools compiler) cannot silently emit wrong-magic
    # bytecode.
    expected_version = _expected_version(target_runtime)

    # One action per source, not per target: a source may be listed by
    # several targets in the same package (e.g. many binaries sharing one
    # module), and all of them declare the same sibling outputs. Bazel only
    # tolerates that when the competing actions are byte-identical, which a
    # per-target batch cannot guarantee (each batch spans a different src
    # set). Per-source actions are identical everywhere, so shared sources
    # analysis-share instead of conflicting.
    pyc_tag = pycache_tag(target_runtime)

    for src in srcs:
        if src.extension != "py":
            continue
        if src.owner.package != ctx.label.package or src.owner.workspace_name != ctx.label.workspace_name:
            # `sibling=` cannot declare an output for a foreign file.
            # Source-retaining pyc mode safely falls back to this source;
            # the pyc_only terminal reports it as missing bytecode.
            continue
        pyc = ctx.actions.declare_file(src.basename[:-3] + ".pyc", sibling = src)
        pycache_basename = "{}.{}.pyc".format(src.basename[:-3], pyc_tag) if pyc_tag else "{}.pyc".format(src.basename[:-3])
        pycache = ctx.actions.declare_file(
            "__pycache__/{}".format(pycache_basename),
            sibling = src,
        )
        compile_args = ctx.actions.args()
        compile_args.add_all(pyc_compile_tool.arguments)
        if expected_version:
            compile_args.add("--expect-version", expected_version)
        compile_args.add("--src", src)
        compile_args.add("--pycache", pycache)
        compile_args.add("--dfile", src.short_path)
        compile_args.add("--pyc", pyc)
        ctx.actions.run(
            executable = pyc_compile_tool.executable,
            toolchain = tool_toolchain,
            arguments = [compile_args],
            inputs = depset(
                direct = [src],
                transitive = [pyc_compile_tool.inputs],
            ),
            outputs = [pycache, pyc],
            mnemonic = "PyCompile",
            progress_message = "Python precompiling %{input} into %{output}",
            env = {
                "PYTHONHASHSEED": "0",
                "PYTHONNOUSERSITE": "1",
                "PYTHONSAFEPATH": "1",
            },
        )
        entries.append(struct(source = src, pyc = pyc, pycache = pycache if pyc_tag else None))
        legacy_files.append(pyc)
        if pyc_tag:
            pycache_files.append(pycache)

    return struct(entries = entries, legacy_files = legacy_files, pycache_files = pycache_files)

def make_pyc_info(compiled, deps = [], resolutions = []):
    """Merge this rule's own compiled bytecode with its dependencies'.

    Args:
        compiled: the struct returned by `compile_pycs` (or None).
        deps: Targets whose FirstPartyPycInfo (when present) is inherited.
        resolutions: additional Targets (virtual-dep resolutions) to inherit.

    Returns:
        FirstPartyPycInfo
    """
    transitive_entries = []
    transitive_legacy_files = []
    transitive_pycache_files = []
    for dep in list(deps) + list(resolutions):
        if FirstPartyPycInfo in dep:
            dep_pyc = dep[FirstPartyPycInfo]
            transitive_entries.append(dep_pyc.entries)
            transitive_legacy_files.append(dep_pyc.legacy_files)
            transitive_pycache_files.append(dep_pyc.pycache_files)

    return FirstPartyPycInfo(
        entries = depset(
            direct = compiled.entries if compiled else [],
            transitive = transitive_entries,
        ),
        legacy_files = depset(
            direct = compiled.legacy_files if compiled else [],
            transitive = transitive_legacy_files,
        ),
        pycache_files = depset(
            direct = compiled.pycache_files if compiled else [],
            transitive = transitive_pycache_files,
        ),
    )
