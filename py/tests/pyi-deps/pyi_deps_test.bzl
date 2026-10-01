"""Analysis tests for `pyi_deps`.

Each test names path fragments that must reach type checkers only, and
fragments that must still reach the runnable program.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//py/private:providers.bzl", "PyWheelsInfo")
load("//py/private:py_info.bzl", "PyInfo")
load("//py/private:py_info_interop.bzl", "RulesPythonPyInfo")

# Resolved here so the label is canonical by the time skylib's transition,
# defined in another repo, receives it.
_EMIT_RULES_PYTHON_PROVIDERS = str(Label("//py/private:emit_rules_python_providers"))

def _paths(files):
    return [file.short_path for file in files.to_list()]

def _has(values, fragment):
    return any([fragment in value for value in values])

def _check(env, values, fragment, expected, where):
    if expected:
        asserts.true(env, _has(values, fragment), "{} is missing from {}".format(fragment, where))
    else:
        asserts.false(env, _has(values, fragment), "{} leaked into {}".format(fragment, where))

_ATTRS = {
    "runtime": attr.string_list(doc = "Fragments that must remain runtime sources."),
    "type_check_only": attr.string_list(mandatory = True, doc = "Fragments only type checkers may see."),
}

def _type_check_only_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    info = target[PyInfo]
    pyi_files = _paths(info.transitive_pyi_files)
    pyi_imports = info.pyi_imports.to_list()
    sources = _paths(info.transitive_sources)
    imports = info.imports.to_list()
    runfiles = _paths(target[DefaultInfo].default_runfiles.files)
    wheels = [wheel.site_packages_rfpath for wheel in target[PyWheelsInfo].wheels.to_list()] if PyWheelsInfo in target else []

    # Libraries keep sources in PyInfo; only executables put them in runfiles.
    executable = target[DefaultInfo].files_to_run.executable != None

    for fragment in ctx.attr.type_check_only:
        _check(env, pyi_files, fragment, True, "transitive_pyi_files")
        _check(env, pyi_imports, fragment, True, "pyi_imports")
        _check(env, sources, fragment, False, "transitive_sources")
        _check(env, imports, fragment, False, "imports")
        _check(env, runfiles, fragment, False, "runfiles")
        _check(env, wheels, fragment, False, "PyWheelsInfo")
    for fragment in ctx.attr.runtime:
        _check(env, sources, fragment, True, "transitive_sources")
        if executable:
            _check(env, runfiles, fragment, True, "runfiles")
    return analysistest.end(env)

# Checks rules_py's PyInfo, plus runfiles and PyWheelsInfo.
type_check_only_test = analysistest.make(_type_check_only_test_impl, attrs = _ATTRS)

def _rules_python_type_check_only_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    info = target[RulesPythonPyInfo]
    for fragment in ctx.attr.type_check_only:
        _check(env, _paths(info.transitive_pyi_files), fragment, True, "transitive_pyi_files")
        _check(env, _paths(info.transitive_sources), fragment, False, "transitive_sources")

        # rules_python merges pyi_deps import roots into `imports`; this is
        # where rules_lint's ty aspect finds them.
        _check(env, info.imports.to_list(), fragment, True, "imports")
    for fragment in ctx.attr.runtime:
        _check(env, _paths(info.transitive_sources), fragment, True, "transitive_sources")
    return analysistest.end(env)

# Checks the @rules_python PyInfo emitted under the migration flag.
rules_python_type_check_only_test = analysistest.make(
    _rules_python_type_check_only_test_impl,
    attrs = _ATTRS,
    config_settings = {
        _EMIT_RULES_PYTHON_PROVIDERS: True,
    },
)
