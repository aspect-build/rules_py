"""Analysis test for deduplicating runtime data across terminal overrides."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//py/private:transitions.bzl", "python_transition", "reset_python_flags_transition")

_DEP_GROUP_FLAG = "@aspect_rules_py//uv/private/constraints/dep_group:dep_group"
_PYTHON_VERSION_FLAG = "@aspect_rules_py//py/private/interpreter:python_version"
_RPY_VERSION_FLAG = "@rules_python//python/config_settings:python_version"
_FREETHREADED_FLAG = "@aspect_rules_py//py/private/interpreter:freethreaded"
_RPY_FREETHREADED_FLAG = "@rules_python//python/config_settings:py_freethreaded"

_ProbeInfo = provider(fields = ["file"])
_ProbeFilesInfo = provider(fields = ["files", "modes"])

def _probe_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(out, "probe")
    return [_ProbeInfo(
        file = out,
    )]

probe = rule(
    implementation = _probe_impl,
)

def _probe_aspect_impl(target, ctx):
    direct = []
    if _ProbeInfo in target:
        direct.append(target[_ProbeInfo].file)

    transitive = []
    transitive_modes = []
    deps = []
    for attr_name in ["data", "deps"]:
        deps.extend(getattr(ctx.rule.attr, attr_name, []))
    venv = getattr(ctx.rule.attr, "venv", None)
    if venv != None:
        deps.append(venv)
    for dep in deps:
        if _ProbeFilesInfo in dep:
            transitive.append(dep[_ProbeFilesInfo].files)
            transitive_modes.append(dep[_ProbeFilesInfo].modes)

    # Record every visited target; the test impl filters to the names it
    # asserts on, keeping the fixture-name coupling in one place.
    modes = [(
        ctx.label.name,
        ctx.attr._freethreaded[BuildSettingInfo].value,
        ctx.attr._rpy_freethreaded[BuildSettingInfo].value,
    )]
    return [_ProbeFilesInfo(
        files = depset(direct = direct, transitive = transitive),
        modes = depset(direct = modes, transitive = transitive_modes),
    )]

_probe_aspect = aspect(
    implementation = _probe_aspect_impl,
    attr_aspects = ["data", "deps", "venv"],
    attrs = {
        "_freethreaded": attr.label(default = _FREETHREADED_FLAG),
        "_rpy_freethreaded": attr.label(default = _RPY_FREETHREADED_FLAG),
    },
)

def _terminal_impl(_ctx):
    return []

# Minimal terminal for exercising nested incoming transitions. The public
# rules below cover their real data attrs; this one isolates baseline
# propagation without adding Python-provider constraints to the fixture graph.
terminal = rule(
    implementation = _terminal_impl,
    attrs = {
        "data": attr.label_list(
            cfg = reset_python_flags_transition,
        ),
        "deps": attr.label_list(),
        "dep_group": attr.string(default = ""),
        "freethreaded": attr.string(default = "", values = ["", "false", "true"]),
        "python_version": attr.string(),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    cfg = python_transition,
)

def _root_impl(ctx):
    transitive = [dep[_ProbeFilesInfo].files for dep in ctx.attr.deps]
    return [_ProbeFilesInfo(
        files = depset(transitive = transitive),
        modes = depset(transitive = [dep[_ProbeFilesInfo].modes for dep in ctx.attr.deps]),
    )]

def _baseline_transition_impl(_settings, _attr):
    return {
        _DEP_GROUP_FLAG: "baseline",
        _PYTHON_VERSION_FLAG: "",
        _RPY_VERSION_FLAG: "3.10",
        # A caller may set only one flag. Terminals synchronize their subtree,
        # but data must restore both original values to share one configuration.
        _FREETHREADED_FLAG: False,
        _RPY_FREETHREADED_FLAG: "yes",
    }

_baseline_transition = transition(
    implementation = _baseline_transition_impl,
    inputs = [],
    outputs = [
        _DEP_GROUP_FLAG,
        _PYTHON_VERSION_FLAG,
        _RPY_VERSION_FLAG,
        _FREETHREADED_FLAG,
        _RPY_FREETHREADED_FLAG,
    ],
)

root = rule(
    implementation = _root_impl,
    attrs = {
        "deps": attr.label_list(
            aspects = [_probe_aspect],
            cfg = _baseline_transition,
            allow_empty = False,
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)

def _reset_data_edges_test_impl(ctx):
    env = analysistest.begin(ctx)
    files = analysistest.target_under_test(env)[_ProbeFilesInfo].files.to_list()
    asserts.equals(
        env,
        1,
        len(files),
        "runtime data should analyze the probe once across terminal overrides",
    )
    expected = [
        ("probe", False, "yes"),
        ("first", True, "yes"),
        ("second", False, "no"),
        ("_launcher.venv", True, "yes"),
        ("_launcher.venv", False, "no"),
        ("parent_terminal", True, "yes"),
        ("nested_terminal", False, "no"),
        ("inherit_terminal", True, "yes"),
    ]
    tracked = {name: True for name, _, _ in expected}
    modes = [
        mode
        for mode in analysistest.target_under_test(env)[_ProbeFilesInfo].modes.to_list()
        if mode[0] in tracked
    ]
    asserts.equals(env, sorted(expected), sorted(modes))
    return analysistest.end(env)

_reset_data_edges_test = analysistest.make(_reset_data_edges_test_impl)

def reset_data_edges_test_suite():
    _reset_data_edges_test(
        name = "reset_data_edges_test",
        target_under_test = ":root",
    )
