"""Analysis test for deduplicating runtime data across terminal overrides."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//py/private:py_info.bzl", "PyInfo")
load("//py/private:transitions.bzl", "python_transition", "reset_python_flags_transition")

_DEP_GROUP_FLAG = "@aspect_rules_py//uv/private/constraints/dep_group:dep_group"
_PYTHON_VERSION_FLAG = "@aspect_rules_py//py/private/interpreter:python_version"
_RPY_VERSION_FLAG = "@rules_python//python/config_settings:python_version"
_FREETHREADED_FLAG = "@aspect_rules_py//py/private/interpreter:freethreaded"
_RPY_FREETHREADED_FLAG = "@rules_python//python/config_settings:py_freethreaded"

_ProbeInfo = provider(fields = ["file"])
_ProbeFilesInfo = provider(fields = ["files", "modes", "bin_dirs"])

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
    if ctx.rule.kind == "py_library":
        direct.extend([f for f in target[PyInfo].transitive_sources.to_list() if not f.is_source])

    transitive = []
    transitive_modes = []
    transitive_bin_dirs = []
    deps = []
    for attr_name in ["data", "deps"]:
        deps.extend(getattr(ctx.rule.attr, attr_name, []))
    venv = getattr(ctx.rule.attr, "venv", None)
    if type(venv) == "list":
        # A transitioned label attr presents as a single-element list.
        deps.extend(venv)
    elif venv != None:
        deps.append(venv)
    for dep in deps:
        if _ProbeFilesInfo in dep:
            transitive.append(dep[_ProbeFilesInfo].files)
            transitive_modes.append(dep[_ProbeFilesInfo].modes)
            transitive_bin_dirs.append(dep[_ProbeFilesInfo].bin_dirs)

    # Record every visited target; the test impl filters to the names it
    # asserts on, keeping the fixture-name coupling in one place.
    modes = [(
        ctx.label.name,
        ctx.attr._freethreaded[BuildSettingInfo].value,
        ctx.attr._rpy_freethreaded[BuildSettingInfo].value,
    )]

    # bin_dir carries the configuration's output segment, so equal paths mean
    # one configuration.
    bin_dirs = [(ctx.label.name, ctx.bin_dir.path)]
    return [_ProbeFilesInfo(
        files = depset(direct = direct, transitive = transitive),
        modes = depset(direct = modes, transitive = transitive_modes),
        bin_dirs = depset(direct = bin_dirs, transitive = transitive_bin_dirs),
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
def _terminal_rule(**attrs):
    return rule(
        implementation = _terminal_impl,
        attrs = dict(
            {
                "data": attr.label_list(
                    cfg = reset_python_flags_transition,
                ),
                "deps": attr.label_list(),
                "dep_group": attr.string(default = ""),
                "python_version": attr.string(),
                "_allowlist_function_transition": attr.label(
                    default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
                ),
            },
            **attrs
        ),
        cfg = python_transition,
    )

terminal = _terminal_rule(freethreaded = attr.string(default = "", values = ["", "false", "true"]))

# Direct transition callers may declare no freethreaded attr at all.
versioned_terminal = _terminal_rule()

def _root_impl(ctx):
    transitive = [dep[_ProbeFilesInfo].files for dep in ctx.attr.deps]
    return [_ProbeFilesInfo(
        files = depset(transitive = transitive),
        modes = depset(transitive = [dep[_ProbeFilesInfo].modes for dep in ctx.attr.deps]),
        bin_dirs = depset(transitive = [dep[_ProbeFilesInfo].bin_dirs for dep in ctx.attr.deps]),
    )]

def _baseline_transition_impl(settings, attr):
    if attr.synced:
        # Keep the configured version so real venvs resolve the registered
        # toolchain; only make rules_python's flag agree with it.
        return {
            _DEP_GROUP_FLAG: "baseline",
            _PYTHON_VERSION_FLAG: settings[_PYTHON_VERSION_FLAG],
            _RPY_VERSION_FLAG: settings[_PYTHON_VERSION_FLAG] or settings[_RPY_VERSION_FLAG],
            _FREETHREADED_FLAG: False,
            _RPY_FREETHREADED_FLAG: "no",
        }

    # A caller may set only one flag. Terminals synchronize their subtree,
    # but data must restore both original values to share one configuration.
    return {
        _DEP_GROUP_FLAG: "baseline",
        _PYTHON_VERSION_FLAG: "",
        _RPY_VERSION_FLAG: settings[_RPY_VERSION_FLAG],
        _FREETHREADED_FLAG: False,
        _RPY_FREETHREADED_FLAG: "yes",
    }

_baseline_transition = transition(
    implementation = _baseline_transition_impl,
    inputs = [
        _PYTHON_VERSION_FLAG,
        _RPY_VERSION_FLAG,
    ],
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
        # Both flag pairs already agree, so a terminal that keeps their values
        # has nothing to synchronize.
        "synced": attr.bool(default = False),
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
        ("no_freethreaded_attr_terminal", True, "yes"),
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

def _passthrough_terminals_test_impl(ctx):
    env = analysistest.begin(ctx)
    files = analysistest.target_under_test(env)[_ProbeFilesInfo].files.to_list()
    asserts.equals(
        env,
        1,
        len(files),
        "terminals that keep the inherited flags should share the caller's configuration",
    )
    return analysistest.end(env)

_passthrough_terminals_test = analysistest.make(_passthrough_terminals_test_impl)

def _shared_binaries_test_impl(ctx):
    env = analysistest.begin(ctx)
    under_test = analysistest.target_under_test(env)[_ProbeFilesInfo]
    generated = [f for f in under_test.files.to_list() if f.basename == "gen.py"]
    asserts.equals(
        env,
        1,
        len(generated),
        "a generated source shared by the binaries and the caller should be one File",
    )

    bin_dirs = {}
    for name, path in under_test.bin_dirs.to_list():
        bin_dirs.setdefault(name, {})[path] = True
    caller = bin_dirs["bin_a"].keys()
    for name in ["bin_b", "_bin_a.venv", "_bin_b.venv", "shared"]:
        asserts.equals(env, caller, bin_dirs[name].keys(), name + " should analyze in the caller's configuration")
    return analysistest.end(env)

_shared_binaries_test = analysistest.make(_shared_binaries_test_impl)

def reset_data_edges_test_suite():
    _reset_data_edges_test(
        name = "reset_data_edges_test",
        target_under_test = ":root",
    )
    _passthrough_terminals_test(
        name = "passthrough_terminals_test",
        target_under_test = ":synced_root",
    )
    _shared_binaries_test(
        name = "shared_binaries_test",
        target_under_test = ":binaries_root",
    )
