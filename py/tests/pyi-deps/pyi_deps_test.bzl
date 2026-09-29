"""Analysis coverage for `pyi_deps`.

A `pyi_deps` target's sources, stubs and wheels travel only in
`PyInfo.transitive_pyi_files`, for type checkers. They stay out of
`transitive_sources`, `imports`, `PyWheelsInfo` and runfiles, so they cost
nothing at run time.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//py/private:providers.bzl", "PyWheelsInfo")
load("//py/private:py_info.bzl", "PyInfo")
load("//py/private:py_info_interop.bzl", "RulesPythonPyInfo")
load("//py/private/py_venv:defs.bzl", "VirtualenvInfo")

# Resolved here so the label is canonical by the time skylib's transition,
# defined in another repo, receives it.
_EMIT_RULES_PYTHON_PROVIDERS = str(Label("//py/private:emit_rules_python_providers"))

def _paths(files):
    return [file.short_path for file in files.to_list()]

def _has(paths, fragment):
    return any([fragment in path for path in paths])

def _runfile_paths(target):
    return _paths(target[DefaultInfo].default_runfiles.files)

def _assert_type_only(env, info, runfiles):
    pyi_paths = _paths(info.transitive_pyi_files)
    asserts.true(env, _has(pyi_paths, "heavy/heavy.py"), "first-party pyi_deps sources reach type checkers")
    asserts.true(env, _has(pyi_paths, "cowsay"), "pyi_deps wheels reach type checkers")
    asserts.false(env, _has(_paths(info.transitive_sources), "heavy/heavy.py"), "pyi_deps are not runtime sources")
    asserts.false(env, _has(_paths(info.transitive_sources), "cowsay"), "pyi_deps wheels are not runtime sources")
    asserts.false(env, _has(info.imports.to_list(), "heavy"), "pyi_deps import roots stay off sys.path")
    asserts.false(env, _has(info.imports.to_list(), "cowsay"), "pyi_deps wheel roots stay off sys.path")
    asserts.true(env, _has(info.pyi_imports.to_list(), "heavy"), "pyi_deps import roots are exposed for type checkers")
    asserts.true(env, _has(info.pyi_imports.to_list(), "cowsay"), "pyi_deps wheel roots are exposed for type checkers")
    asserts.false(env, _has(runfiles, "heavy/heavy.py"), "pyi_deps sources stay out of runfiles")
    asserts.false(env, _has(runfiles, "cowsay"), "pyi_deps wheels stay out of runfiles")

def _assert_no_wheels(env, target):
    wheels = target[PyWheelsInfo].wheels.to_list() if PyWheelsInfo in target else []
    asserts.equals(env, [], wheels, "pyi_deps wheels are not linked into site-packages")

def _library_pyi_deps_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    _assert_type_only(env, target[PyInfo], _runfile_paths(target))
    _assert_no_wheels(env, target)
    return analysistest.end(env)

library_pyi_deps_test = analysistest.make(_library_pyi_deps_test_impl)

def _transitive_pyi_deps_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    _assert_type_only(env, target[PyInfo], _runfile_paths(target))
    _assert_no_wheels(env, target)
    asserts.true(env, _has(_paths(target[PyInfo].transitive_sources), "typed.py"), "ordinary deps still travel")
    return analysistest.end(env)

transitive_pyi_deps_test = analysistest.make(_transitive_pyi_deps_test_impl)

def _launcher_pyi_deps_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    runfiles = _runfile_paths(target)
    _assert_type_only(env, target[PyInfo], runfiles)
    asserts.true(env, _has(runfiles, "typed.py"), "ordinary deps still reach runfiles")
    return analysistest.end(env)

launcher_pyi_deps_test = analysistest.make(_launcher_pyi_deps_test_impl)

def _resolution_pyi_deps_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    info = target[PyInfo]
    asserts.true(env, _has(_paths(info.transitive_pyi_files), "heavy/heavy.py"), "a resolution's pyi_deps reach type checkers")
    asserts.true(env, _has(info.pyi_imports.to_list(), "heavy"), "a resolution's pyi_deps import roots reach type checkers")
    asserts.false(env, _has(info.imports.to_list(), "heavy"), "a resolution's pyi_deps stay off sys.path")
    asserts.false(env, _has(_runfile_paths(target), "heavy/heavy.py"), "a resolution's pyi_deps stay out of runfiles")
    return analysistest.end(env)

resolution_pyi_deps_test = analysistest.make(_resolution_pyi_deps_test_impl)

def _venv_pyi_deps_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    info = target[VirtualenvInfo]
    _assert_type_only(env, info, _runfile_paths(target))
    return analysistest.end(env)

venv_pyi_deps_test = analysistest.make(_venv_pyi_deps_test_impl)

def _rules_python_provider_pyi_deps_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    info = target[RulesPythonPyInfo]
    pyi_paths = _paths(info.transitive_pyi_files)
    asserts.true(env, _has(pyi_paths, "heavy/heavy.py"))
    asserts.false(env, _has(_paths(info.transitive_sources), "heavy/heavy.py"), "@rules_python consumers never see pyi_deps as sources")
    asserts.true(env, _has(info.imports.to_list(), "heavy"), "import roots merge as rules_python merges pyi_deps")
    asserts.true(env, _has(info.imports.to_list(), "cowsay"), "including roots reached through a dependency's pyi_deps")
    return analysistest.end(env)

# Under the migration flag the emitted @rules_python provider carries the
# pyi_deps import roots too, so rules_lint's ty aspect can resolve them.
rules_python_provider_pyi_deps_test = analysistest.make(
    _rules_python_provider_pyi_deps_test_impl,
    config_settings = {
        _EMIT_RULES_PYTHON_PROVIDERS: True,
    },
)
