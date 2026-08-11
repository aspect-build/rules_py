"""First-party Python bytecode compilation.

This intentionally does not extend ``PyInfo``.  ``PyInfo`` remains the
source/import graph contract; this aspect is a target-runtime-specific view of
that graph.  An aspect application is memoized by Bazel, so two venvs that
reach the same configured ``py_library`` share its compile actions.
"""

load("//py/private:py_info.bzl", "PyInfo")
load("//py/private/py_venv:types.bzl", "PY_VENV_KINDS")
load("//py/private/toolchain:types.bzl", "EXEC_TOOLS_TOOLCHAIN", "PY_TOOLCHAIN")

FirstPartyPycInfo = provider(
    doc = "Private: first-party Python bytecode artifacts.",
    fields = {
        "entries": "depset[struct(source, pyc, pycache)] — transitive bytecode mappings.",
        "legacy_files": "depset[File] — colocated sourceless .pyc files.",
        "pycache_files": "depset[File] — PEP 3147 __pycache__ files for source-retaining mode.",
    },
)

FirstPartyPycModeInfo = provider(
    doc = "Private: effective first-party bytecode mode of a runnable target.",
    fields = {"mode": "One of source, pyc, or pyc_only."},
)

_PRERELEASE_ABBREVS = {"alpha": "a", "beta": "b", "candidate": "rc"}

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
    return (
        str(getattr(version_info, "major", None)),
        str(getattr(version_info, "minor", None)),
        str(getattr(version_info, "micro", None)),
        str(getattr(version_info, "releaselevel", None)),
        str(getattr(version_info, "serial", None)),
        str(getattr(runtime, "abi_flags", None) or ""),
    )

def _bytecode_compatible(exec_runtime, target_runtime):
    # Bytecode is platform-independent; an exec interpreter is usable iff it
    # is the exact same CPython version (+ABI) as the target runtime. Needed
    # because exec-tools resolution gates on major.minor only and carries an
    # ungated any-version fallback.
    target_key = _bytecode_key(target_runtime)
    return target_key != None and target_key == _bytecode_key(exec_runtime)

def _label_targets(value):
    if type(value) == "Target":
        return [value]
    if type(value) == "list":
        return [v for v in value if type(v) == "Target"]
    if type(value) == "dict":
        return [v for v in value.keys() if type(v) == "Target"]
    return []

def _first_party_pyc_aspect_impl(target, ctx):
    # py_venv_exec re-exports this provider from its pyc_venv.  Applying the
    # aspect to it through another Python edge must not provide it a second
    # time (Bazel rejects duplicate providers).
    if FirstPartyPycInfo in target:
        return []

    transitive_entries = []
    transitive_legacy_files = []
    transitive_pycache_files = []
    for attr_name in ("deps", "venv", "pyc_venv", "resolutions"):
        for dep in _label_targets(getattr(ctx.rule.attr, attr_name, None)):
            if FirstPartyPycInfo in dep:
                dep_pyc = dep[FirstPartyPycInfo]
                transitive_entries.append(dep_pyc.entries)
                transitive_legacy_files.append(dep_pyc.legacy_files)
                transitive_pycache_files.append(dep_pyc.pycache_files)

    direct_entries = []
    direct_legacy_files = []
    direct_pycache_files = []
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
        if exec_runtime != None and getattr(exec_runtime, "interpreter", None) != None and _bytecode_compatible(exec_runtime, target_runtime):
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

    # Verified by the compiler so a mismatched `pyc_compile_tool` (or, later,
    # an exec-tools compiler) cannot silently emit wrong-magic bytecode.
    expected_version = _expected_version(target_runtime) if target_runtime != None else None

    # Only compile sources directly owned by this target. Compiling a
    # transitive closure here would duplicate actions at every parent.
    if target_runtime != None and pyc_compile_tool != None and (PyInfo in target or ctx.rule.kind in PY_VENV_KINDS):
        # ``srcs`` is the direct source set for both py_* rules and py_venv.
        # Do not flatten DefaultInfo or VirtualenvInfo: their transitive source
        # closures are larger and require materializing a depset at every
        # aspect node.
        candidates = getattr(ctx.rule.files, "srcs", [])
        for src in candidates:
            # ``sibling=`` preserves the source's natural runfiles location.
            # Bazel only permits that when this aspect target owns the source
            # package; foreign sources are expected to be compiled by their
            # own aspect node. A terminal validates that none remain.
            if src.extension != "py":
                continue
            source_repo = str(src.owner).split("//", 1)[0]
            target_repo = str(ctx.label).split("//", 1)[0]
            if src.owner.package != ctx.label.package or source_repo != target_repo:
                # `sibling=` cannot declare an output for a foreign file.
                # Source-retaining pyc mode safely falls back to this source;
                # the pyc_only terminal reports it as missing bytecode.
                continue
            pyc = ctx.actions.declare_file(src.basename[:-3] + ".pyc", sibling = src)
            pyc_tag = getattr(target_runtime, "pyc_tag", None)
            if not pyc_tag:
                version = getattr(target_runtime, "interpreter_version_info", None)
                if version == None:
                    fail("{}: Python runtime must provide pyc_tag or interpreter_version_info for bytecode compilation".format(ctx.label))
                pyc_tag = "cpython-{}{}".format(version.major, version.minor)
            pycache = ctx.actions.declare_file(
                "__pycache__/{}.{}.pyc".format(src.basename[:-3], pyc_tag),
                sibling = src,
            )
            compile_args = ctx.actions.args()
            compile_args.add_all(pyc_compile_tool.arguments)
            compile_args.add("--src")
            compile_args.add(src)
            compile_args.add("--pycache")
            compile_args.add(pycache)
            compile_args.add("--dfile")
            compile_args.add(src.short_path)
            compile_args.add("--pyc")
            compile_args.add(pyc)
            if expected_version:
                compile_args.add("--expect-version")
                compile_args.add(expected_version)
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
            direct_entries.append(struct(source = src, pyc = pyc, pycache = pycache))
            direct_legacy_files.append(pyc)
            direct_pycache_files.append(pycache)

    pyc_info = FirstPartyPycInfo(
        entries = depset(direct = direct_entries, transitive = transitive_entries),
        legacy_files = depset(direct = direct_legacy_files, transitive = transitive_legacy_files),
        pycache_files = depset(direct = direct_pycache_files, transitive = transitive_pycache_files),
    )
    return [pyc_info]

first_party_pyc_aspect = aspect(
    implementation = _first_party_pyc_aspect_impl,
    attr_aspects = ["deps", "venv", "pyc_venv", "resolutions"],
    attrs = {
        # Fallback compiler script for toolchains carrying no pyc_compile_tool.
        "_pyc_compiler": attr.label(
            default = "//py/private:pyc_compile.py",
            allow_single_file = True,
        ),
    },
    toolchains = [
        PY_TOOLCHAIN,
        # Optional: absent for rules_python users and platforms provisioned
        # with register_exec_tools = False.
        config_common.toolchain_type(EXEC_TOOLS_TOOLCHAIN, mandatory = False),
    ],
    provides = [FirstPartyPycInfo],
)
