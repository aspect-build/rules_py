"""Analysis coverage for `.pyi` type-stub propagation.

Stubs travel in `PyInfo.transitive_pyi_files`, partitioned away from
`transitive_sources`, whether they were listed in a rules_py `srcs`, reached
through a `@rules_python` dependency, or pulled in by a virtual-dependency
resolution. Venvs and launchers put them in runfiles next to the modules they
annotate.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//py/private:py_info.bzl", "PyInfo")
load("//py/private:py_info_interop.bzl", "RulesPythonPyInfo")
load("//py/private/py_venv:defs.bzl", "VirtualenvInfo")

_ALL_STUBS = ["annotated.pyi", "foreign.pyi", "stubby.pyi"]

# Resolved here so the label is canonical by the time skylib's transition,
# defined in another repo, receives it.
_EMIT_RULES_PYTHON_PROVIDERS = str(Label("//py/private:emit_rules_python_providers"))

def _rules_python_pyi_fixture_impl(ctx):
    return [RulesPythonPyInfo(
        transitive_sources = depset(),
        direct_pyi_files = depset(ctx.files.srcs),
        transitive_pyi_files = depset(ctx.files.srcs),
    )]

# Stands in for a py_proto_library: a target whose only Python payload is
# stubs, advertised solely through @rules_python's provider.
rules_python_pyi_fixture = rule(
    implementation = _rules_python_pyi_fixture_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = [".pyi"]),
    },
)

def _basenames(files):
    return sorted([file.basename for file in files.to_list()])

def _has(paths, suffix):
    return any([path.endswith(suffix) for path in paths])

def _runfile_paths(target):
    return [file.short_path for file in target[DefaultInfo].default_runfiles.files.to_list()]

def _first_party_stubs_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.equals(env, ["annotated.pyi"], _basenames(target[PyInfo].transitive_pyi_files))
    asserts.equals(env, ["annotated.py"], _basenames(target[PyInfo].transitive_sources), "stubs are not runtime sources")
    asserts.equals(env, ["annotated.py", "annotated.pyi"], _basenames(target[DefaultInfo].files), "default outputs keep every listed src")
    return analysistest.end(env)

first_party_stubs_test = analysistest.make(_first_party_stubs_test_impl)

def _merged_stubs_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.equals(env, ["annotated.pyi", "foreign.pyi"], _basenames(target[PyInfo].transitive_pyi_files))
    asserts.equals(env, ["annotated.py"], _basenames(target[PyInfo].transitive_sources), "a stubs-only foreign dep contributes no runtime sources")
    return analysistest.end(env)

merged_stubs_test = analysistest.make(_merged_stubs_test_impl)

def _launcher_stubs_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.equals(env, _ALL_STUBS, _basenames(target[PyInfo].transitive_pyi_files), "the launcher surfaces the venv's stub closure, resolutions included")
    asserts.false(env, _has(_basenames(target[PyInfo].transitive_sources), ".pyi"))
    paths = _runfile_paths(target)
    for stub in _ALL_STUBS:
        asserts.true(env, _has(paths, "/" + stub), "launcher runfiles carry " + stub)
    asserts.true(env, _has(paths, "/stubby.py"), "resolved runtime sources still travel")
    return analysistest.end(env)

launcher_stubs_test = analysistest.make(_launcher_stubs_test_impl)

def _venv_stubs_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.equals(env, _ALL_STUBS, _basenames(target[VirtualenvInfo].transitive_pyi_files))
    paths = _runfile_paths(target)
    for stub in _ALL_STUBS:
        asserts.true(env, _has(paths, "/" + stub), "public venv runfiles carry " + stub)
    return analysistest.end(env)

venv_stubs_test = analysistest.make(_venv_stubs_test_impl)

def _rules_python_provider_stubs_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    info = target[RulesPythonPyInfo]
    asserts.equals(env, ctx.attr.expected_direct, _basenames(info.direct_pyi_files))
    asserts.equals(env, ctx.attr.expected_transitive, _basenames(info.transitive_pyi_files))
    asserts.false(env, _has(_basenames(info.transitive_sources), ".pyi"), "@rules_python consumers never see stubs as sources")
    return analysistest.end(env)

# Under the migration flag the emitted @rules_python provider mirrors the
# stub partition, so a rules_python type-check aspect over a half-migrated
# tree sees the same closure on both sides of the boundary.
rules_python_provider_stubs_test = analysistest.make(
    _rules_python_provider_stubs_test_impl,
    attrs = {
        "expected_direct": attr.string_list(mandatory = True),
        "expected_transitive": attr.string_list(mandatory = True),
    },
    config_settings = {
        _EMIT_RULES_PYTHON_PROVIDERS: True,
    },
)
