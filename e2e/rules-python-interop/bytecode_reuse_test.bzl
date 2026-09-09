"""Asserts which bytecode layout rules_py reuses from a rules_python library."""

load("@aspect_rules_py//py/private:providers.bzl", "PycInfo")
load("@aspect_rules_py//py/private:pyc.bzl", "pyc_aspect")
load("@aspect_rules_py//py/tests:pyc_testing.bzl", "precompile_transition")
load("@rules_python//python:py_info.bzl", "PyInfo")

def _bytecode_reuse_check_impl(ctx):
    info = ctx.attr.library[0][PyInfo]
    advertised = depset(transitive = [info.direct_pyc_files, info.transitive_implicit_pyc_files]).to_list()
    entries = ctx.attr.library[0][PycInfo].direct_entries
    if len(entries) != 1:
        fail("{}: expected one bytecode entry, got {}".format(ctx.label, entries))
    entry = entries[0]
    reused = {"pycache": entry.pycache in advertised, "pyc": entry.pyc in advertised}
    expected = {"pycache": ctx.attr.reused == "pycache", "pyc": ctx.attr.reused == "pyc"}
    if reused != expected:
        fail("{}: reused rules_python bytecode {}, expected {}".format(ctx.label, reused, expected))
    return [DefaultInfo()]

bytecode_reuse_check = rule(
    implementation = _bytecode_reuse_check_impl,
    attrs = {
        "library": attr.label(aspects = [pyc_aspect], cfg = precompile_transition, providers = [PyInfo]),
        "reused": attr.string(values = ["none", "pyc", "pycache"]),
    },
)

_PYC = "@aspect_rules_py//py:precompile"
_PRECOMPILE = "@rules_python//python/config_settings:precompile"
_RETENTION = "@rules_python//python/config_settings:precompile_source_retention"

def _precompile_transition_impl(settings, attr):
    return {
        _PYC: "pycache",
        _PRECOMPILE: attr.precompile or settings[_PRECOMPILE],
        _RETENTION: attr.precompile_source_retention or settings[_RETENTION],
    }

_precompile_transition = transition(
    implementation = _precompile_transition_impl,
    inputs = [_PRECOMPILE, _RETENTION],
    outputs = [_PYC, _PRECOMPILE, _RETENTION],
)

_RuleBytecodeInfo = provider(
    doc = "Private: bytecode outputs of the rule's own actions, excluding aspects'.",
    fields = {"paths": "dict[str, bool]"},
)

def _rule_bytecode_aspect_impl(target, _ctx):
    return [_RuleBytecodeInfo(paths = {
        out.path: True
        for action in target.actions
        for out in action.outputs.to_list()
        if out.extension == "pyc"
    })]

_rule_bytecode_aspect = aspect(implementation = _rule_bytecode_aspect_impl)

def _bytecode_producers_impl(ctx):
    library = ctx.attr.library[0]
    own = library[_RuleBytecodeInfo].paths
    entries = library[PycInfo].direct_entries
    if len(entries) != 1:
        fail("{}: expected one bytecode entry, got {}".format(ctx.label, entries))
    producer = lambda f: "rules_python" if f.path in own else "rules_py"
    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(out, "pycache={}\npyc={}\n".format(producer(entries[0].pycache), producer(entries[0].pyc)))
    return [DefaultInfo(files = depset([out]))]

bytecode_producers = rule(
    doc = "Which ruleset's actions produce each bytecode layout of `library` under the given rules_python settings.",
    implementation = _bytecode_producers_impl,
    attrs = {
        "library": attr.label(
            aspects = [pyc_aspect, _rule_bytecode_aspect],
            cfg = _precompile_transition,
            providers = [PyInfo],
        ),
        "precompile": attr.string(),
        "precompile_source_retention": attr.string(),
    },
)
