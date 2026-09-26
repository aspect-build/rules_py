"""Bytecode test helpers: run or inspect targets under chosen flags.

Each probe writes what it observes to a file for `diff_test`, so assertions are
made on built artifacts rather than in analysis tests.
"""

load("@bazel_skylib//rules:diff_test.bzl", "diff_test")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("//py/private:providers.bzl", "PycInfo")
load("//py/private:transitions.bzl", "PYC_FLAG")

_PYC_SHARDS = str(Label("//py:pyc_shards"))
_PRECOMPILE = str(Label("@rules_python//python/config_settings:precompile"))
_RETENTION = str(Label("@rules_python//python/config_settings:precompile_source_retention"))
_COVERAGE = "//command_line_option:collect_code_coverage"
_EXTRA_TOOLCHAINS = "//command_line_option:extra_toolchains"
_FLAGS = [PYC_FLAG, _PYC_SHARDS, _PRECOMPILE, _RETENTION, _COVERAGE]

_CONFIG_ATTRS = {
    "precompile": attr.string(doc = "`--@aspect_rules_py//py:precompile` value; empty keeps the current one."),
    "pyc_shards": attr.string(doc = "`--@aspect_rules_py//py:pyc_shards` value; empty keeps the current one."),
    "rules_python_precompile": attr.string(doc = "rules_python `precompile` value; empty keeps the current one."),
    "rules_python_precompile_source_retention": attr.string(doc = "rules_python `precompile_source_retention` value; empty keeps the current one."),
    "collect_code_coverage": attr.bool(doc = "Whether to instrument for coverage."),
}

def _config(settings, attr, mode):
    out = {flag: settings[flag] for flag in _FLAGS}
    if mode:
        out[PYC_FLAG] = mode
    if attr.pyc_shards:
        out[_PYC_SHARDS] = int(attr.pyc_shards)
    if attr.rules_python_precompile:
        out[_PRECOMPILE] = attr.rules_python_precompile
    if attr.rules_python_precompile_source_retention:
        out[_RETENTION] = attr.rules_python_precompile_source_retention
    if attr.collect_code_coverage:
        out[_COVERAGE] = True
    return out

def _config_transition_impl(settings, attr):
    return _config(settings, attr, attr.precompile)

_config_transition = transition(
    implementation = _config_transition_impl,
    inputs = _FLAGS,
    outputs = _FLAGS,
)

def _modes_transition_impl(settings, attr):
    return {mode or "current": _config(settings, attr, mode) for mode in attr.modes or [attr.precompile]}

_modes_transition = transition(
    implementation = _modes_transition_impl,
    inputs = _FLAGS,
    outputs = _FLAGS,
)

def _pyc_config_run_impl(ctx):
    target = ctx.attr.target[0]
    executable = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(output = executable, target_file = target[DefaultInfo].files_to_run.executable, is_executable = True)
    env = dict(target[RunEnvironmentInfo].environment) if RunEnvironmentInfo in target else {}
    env.update(ctx.attr.env)
    inherited = target[RunEnvironmentInfo].inherited_environment if RunEnvironmentInfo in target else []
    return [
        DefaultInfo(
            executable = executable,
            runfiles = ctx.runfiles([executable]).merge(target[DefaultInfo].default_runfiles),
        ),
        RunEnvironmentInfo(environment = env, inherited_environment = inherited),
    ]

_RUN_ATTRS = _CONFIG_ATTRS | {
    "target": attr.label(executable = True, cfg = _config_transition, mandatory = True),
    "env": attr.string_dict(doc = "Environment added to the target's own."),
}

pyc_config_test = rule(
    doc = "Runs a test or binary as a test under the given flags.",
    implementation = _pyc_config_run_impl,
    attrs = _RUN_ATTRS,
    test = True,
)

def _pyc_config_files_impl(ctx):
    return [DefaultInfo(files = depset(transitive = [src[DefaultInfo].files for src in ctx.attr.srcs]))]

pyc_config_files = rule(
    doc = "The default outputs of `srcs` built under the given flags.",
    implementation = _pyc_config_files_impl,
    attrs = _CONFIG_ATTRS | {
        "srcs": attr.label_list(cfg = _config_transition, mandatory = True),
    },
)

_CompileActionsInfo = provider(
    doc = "Private: first outputs of PyCompile actions across a dependency closure.",
    fields = {"keys": "depset[str]"},
)

_CLOSURE_ATTRS = ["binary", "data", "deps", "srcs", "venv"]

def _compile_actions_aspect_impl(target, ctx):
    keys = [action.outputs.to_list()[0].path for action in target.actions if action.mnemonic == "PyCompile"]
    transitive = []
    for name in _CLOSURE_ATTRS:
        value = getattr(ctx.rule.attr, name, None)
        for dep in value if type(value) == "list" else [value]:
            if type(dep) == "Target" and _CompileActionsInfo in dep:
                transitive.append(dep[_CompileActionsInfo].keys)
    return [_CompileActionsInfo(keys = depset(keys, transitive = transitive))]

_compile_actions_aspect = aspect(
    implementation = _compile_actions_aspect_impl,
    attr_aspects = _CLOSURE_ATTRS,
)

def _compile_action_count_impl(ctx):
    keys = depset(transitive = [
        target[_CompileActionsInfo].keys
        for targets in ctx.split_attr.targets.values()
        for target in targets
    ])
    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(out, "{}\n".format(len(keys.to_list())))
    return [DefaultInfo(files = depset([out]))]

compile_action_count = rule(
    doc = """Distinct rules_py PyCompile actions across the closures of `targets`,
analyzed once per entry of `modes` (the current configuration when empty).""",
    implementation = _compile_action_count_impl,
    attrs = _CONFIG_ATTRS | {
        "modes": attr.string_list(doc = "precompile modes to analyze `targets` under."),
        "targets": attr.label_list(cfg = _modes_transition, aspects = [_compile_actions_aspect], mandatory = True),
    },
)

def _bytecode_sources_impl(ctx):
    sources = sorted({entry.source.short_path: True for entry in ctx.attr.target[0][PycInfo].entries.to_list()}.keys())
    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(out, "".join([source + "\n" for source in sources]))
    return [DefaultInfo(files = depset([out]))]

bytecode_sources = rule(
    doc = "The sources `target` carries bytecode for, one short path per line.",
    implementation = _bytecode_sources_impl,
    attrs = _CONFIG_ATTRS | {
        "target": attr.label(providers = [PycInfo], cfg = _config_transition, mandatory = True),
    },
)

def _runfiles_with_suffix_impl(ctx):
    paths = sorted([f.short_path for f in ctx.attr.target[0][DefaultInfo].default_runfiles.files.to_list() if f.short_path.endswith(ctx.attr.suffix)])
    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(out, "".join([path + "\n" for path in paths]))
    return [DefaultInfo(files = depset([out]))]

runfiles_with_suffix = rule(
    doc = "The runfiles of `target` ending in `suffix`, one short path per line.",
    implementation = _runfiles_with_suffix_impl,
    attrs = _CONFIG_ATTRS | {
        "suffix": attr.string(mandatory = True),
        "target": attr.label(cfg = _config_transition, mandatory = True),
    },
)

def _output_configuration_impl(ctx):
    roots = {f.root.path: True for f in ctx.attr.target[DefaultInfo].files.to_list()}
    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(out, ("requesting" if roots.keys() == [ctx.bin_dir.path] else "other: " + ", ".join(roots.keys())) + "\n")
    return [DefaultInfo(files = depset([out]))]

output_configuration = rule(
    doc = "`requesting` when every default output of `target` is in this rule's configuration.",
    implementation = _output_configuration_impl,
    attrs = {"target": attr.label(mandatory = True)},
)

def _library_configuration_impl(ctx):
    paths = _bytecode_paths(ctx.attr.lib)
    roots = {entry.pyc.root.path: True for entry in ctx.attr.lib[PycInfo].direct_entries}
    launcher_paths = {entry.pyc.path: True for entry in ctx.attr.launcher[PycInfo].entries.to_list()}
    lines = [
        "requesting" if roots.keys() == [ctx.bin_dir.path] else "other: " + ", ".join(roots.keys()),
        "shared" if all([path in launcher_paths for path in paths]) else "unshared",
    ]
    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(out, "".join([line + "\n" for line in lines]))
    return [DefaultInfo(files = depset([out]))]

library_configuration = rule(
    doc = "Under `precompile`, whether `lib` compiles in the requesting configuration, into the files `launcher` ships.",
    implementation = _library_configuration_impl,
    cfg = _config_transition,
    attrs = _CONFIG_ATTRS | {
        "launcher": attr.label(providers = [PycInfo], mandatory = True),
        "lib": attr.label(providers = [PycInfo], mandatory = True),
    },
)

def _dependency_configuration_impl(ctx):
    launcher = ctx.attr.launcher
    consumed = {f.path: True for f in launcher[DefaultInfo].default_runfiles.files.to_list()}
    if PycInfo in launcher:
        consumed.update({entry.source.path: True for entry in launcher[PycInfo].entries.to_list()})
    shared = all([f.path in consumed for f in ctx.attr.dep[DefaultInfo].files.to_list()])
    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(out, ("shared" if shared else "unshared") + "\n")
    return [DefaultInfo(files = depset([out]))]

dependency_configuration = rule(
    doc = "Under `precompile`, `shared` when `launcher` ships or compiles `dep`'s outputs as built in the requesting configuration.",
    implementation = _dependency_configuration_impl,
    cfg = _config_transition,
    attrs = _CONFIG_ATTRS | {
        "dep": attr.label(mandatory = True),
        "launcher": attr.label(mandatory = True),
    },
)

def _extra_toolchain_transition_impl(settings, attr):
    return {
        _EXTRA_TOOLCHAINS: [str(attr.toolchain)] + settings[_EXTRA_TOOLCHAINS],
        PYC_FLAG: "pycache",
    }

_extra_toolchain_transition = transition(
    implementation = _extra_toolchain_transition_impl,
    inputs = [_EXTRA_TOOLCHAINS],
    outputs = [_EXTRA_TOOLCHAINS, PYC_FLAG],
)

def _precompile_transition_impl(_settings, _attr):
    return {PYC_FLAG: "pycache"}

# Libraries, including rules_python ones, compile only below a bytecode request.
precompile_transition = transition(
    implementation = _precompile_transition_impl,
    inputs = [],
    outputs = [PYC_FLAG],
)

def _compiled_source_count_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(out, "{}\n".format(len(ctx.attr.lib[0][PycInfo].direct_entries)))
    return [DefaultInfo(files = depset([out]))]

compiled_source_count = rule(
    doc = "Number of `lib` sources compiled when `toolchain` is registered first.",
    implementation = _compiled_source_count_impl,
    attrs = {
        "lib": attr.label(providers = [PycInfo], cfg = _extra_toolchain_transition),
        "toolchain": attr.label(),
    },
)

def _bytecode_paths(target):
    paths = [entry.pyc.path for entry in target[PycInfo].direct_entries]
    if not paths:
        fail("{} compiled no bytecode".format(target.label))
    return paths

def _shared_bytecode_impl(ctx):
    paths = [_bytecode_paths(target) for target in ctx.split_attr.lib.values()]
    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(out, ("same" if all([p == paths[0] for p in paths]) else "different") + "\n")
    return [DefaultInfo(files = depset([out]))]

shared_bytecode = rule(
    doc = "`same` when `lib` compiles into the same files under every entry of `modes`.",
    implementation = _shared_bytecode_impl,
    attrs = _CONFIG_ATTRS | {
        "lib": attr.label(providers = [PycInfo], cfg = _modes_transition, mandatory = True),
        "modes": attr.string_list(mandatory = True),
    },
)

_ProducersInfo = provider(doc = "Private: one line per bytecode entry naming its producer.", fields = ["lines"])

def _producers_aspect_impl(target, _ctx):
    producers = {}
    for action in target.actions:
        for out in action.outputs.to_list():
            producers[out.path] = action
    lines = []
    for entry in target[PycInfo].direct_entries:
        pycache = producers.get(entry.pycache.path)
        pyc = producers.get(entry.pyc.path)
        if pycache != None and pycache == pyc:
            lines.append("{} {}".format(entry.source.short_path, pycache.mnemonic))
        else:
            lines.append("{} split {} {}".format(
                entry.source.short_path,
                getattr(pycache, "mnemonic", None),
                getattr(pyc, "mnemonic", None),
            ))
    return [_ProducersInfo(lines = sorted(lines))]

_producers_aspect = aspect(implementation = _producers_aspect_impl)

def _bytecode_producers_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(out, "".join([line + "\n" for line in ctx.attr.target[0][_ProducersInfo].lines]))
    return [DefaultInfo(files = depset([out]))]

bytecode_producers = rule(
    doc = "For each bytecode entry of `target`, the action writing both layouts, or `split` when two actions do.",
    implementation = _bytecode_producers_impl,
    attrs = {"target": attr.label(aspects = [_producers_aspect], cfg = precompile_transition, mandatory = True)},
)

def expect_test(name, actual, lines, **kwargs):
    """Asserts the single output of `actual` reads `lines`, one per line."""
    write_file(
        name = name + "_expected",
        out = name + "_expected.txt",
        content = lines + [""],
        newline = "unix",
        **kwargs
    )
    diff_test(
        name = name,
        file1 = actual,
        file2 = ":" + name + "_expected",
        **kwargs
    )

def _probe_test(probe, render):
    def macro(name, expected, **kwargs):
        kwargs.setdefault("testonly", True)
        probe(name = name + "_actual", **kwargs)
        expect_test(name, ":" + name + "_actual", render(expected))

    return macro

_one = lambda value: [str(value)]
_each = lambda values: list(values)

compile_action_count_test = _probe_test(compile_action_count, _one)
compiled_source_count_test = _probe_test(compiled_source_count, _one)
shared_bytecode_test = _probe_test(shared_bytecode, _one)
output_configuration_test = _probe_test(output_configuration, _one)
library_configuration_test = _probe_test(library_configuration, _each)
dependency_configuration_test = _probe_test(dependency_configuration, _one)
bytecode_sources_test = _probe_test(bytecode_sources, _each)
runfiles_with_suffix_test = _probe_test(runfiles_with_suffix, _each)
bytecode_producers_test = _probe_test(bytecode_producers, _each)
