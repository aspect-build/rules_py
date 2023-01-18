load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//py/private:py_library.bzl", _py_library = "py_library", py_library = "py_library_utils")

def _ctx_with_imports(imports, deps = []):
    return struct(
        attr = struct(
            deps = deps,
            imports = imports,
        ),
        build_file_path = "foo/bar/BUILD.bazel",
        workspace_name = "aspect_rules_py",
        label = Label("//foo/bar:baz"),
    )

def _can_resolve_path_in_workspace_test_impl(ctx):
    env = unittest.begin(ctx)

    # The import path is the current package
    fake_ctx = _ctx_with_imports(["."])
    imports = py_library.make_imports_depset(fake_ctx).to_list()
    asserts.equals(env, "aspect_rules_py/foo/bar", imports[0])

    # Empty string import is semantically equal to "."
    fake_ctx = _ctx_with_imports([""])
    imports = py_library.make_imports_depset(fake_ctx).to_list()
    asserts.equals(env, "aspect_rules_py/foo/bar", imports[0])

    # Empty imports array results in just the workspace root import
    fake_ctx = _ctx_with_imports([])
    imports = py_library.make_imports_depset(fake_ctx).to_list()
    asserts.equals(env, 1, len(imports))
    asserts.equals(env, "aspect_rules_py", imports[0])

    # The import path is the parent package
    fake_ctx = _ctx_with_imports([".."])
    imports = py_library.make_imports_depset(fake_ctx).to_list()
    asserts.equals(env, "aspect_rules_py/foo", imports[0])

    # The import path is both the current and parent package
    fake_ctx = _ctx_with_imports([".", ".."])
    imports = py_library.make_imports_depset(fake_ctx).to_list()
    asserts.equals(env, "aspect_rules_py/foo/bar", imports[0])
    asserts.equals(env, "aspect_rules_py/foo", imports[1])

    # The import path is the current package, but with trailing /
    fake_ctx = _ctx_with_imports(["./"])
    imports = py_library.make_imports_depset(fake_ctx).to_list()
    asserts.equals(env, "aspect_rules_py/foo/bar", imports[0])

    # The import path has some other child path in it
    fake_ctx = _ctx_with_imports(["./baz"])
    imports = py_library.make_imports_depset(fake_ctx).to_list()
    asserts.equals(env, "aspect_rules_py/foo/bar/baz", imports[0])

    # The import path is at the root
    fake_ctx = _ctx_with_imports(["../.."])
    imports = py_library.make_imports_depset(fake_ctx).to_list()
    asserts.equals(env, "aspect_rules_py", imports[0])

    # The relative import path is longer than the path from the root
    fake_ctx = _ctx_with_imports(["../some/python/library/imp/path"])
    imports = py_library.make_imports_depset(fake_ctx).to_list()
    asserts.equals(env, "aspect_rules_py/foo/some/python/library/imp/path", imports[0])

    # Transitive imports are included in depset
    fake_ctx = _ctx_with_imports([".."], [ctx.attr.import_dep])
    imports = py_library.make_imports_depset(fake_ctx).to_list()
    asserts.equals(env, "aspect_rules_py/py/tests/import-pathing/baz", imports[0])
    asserts.equals(env, "aspect_rules_py/foo", imports[1])

    return unittest.end(env)

_can_resolve_path_in_workspace_test = unittest.make(
    _can_resolve_path_in_workspace_test_impl,
    attrs = {
        "import_dep": attr.label(
            default = "//py/tests/import-pathing:__native_rule_import_list_for_test",
        ),
    },
)

def _fails_on_imp_path_that_breaks_workspace_root_imp(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "Import paths must not escape the workspace root")
    return analysistest.end(env)

_fails_on_imp_path_that_breaks_workspace_root_test = analysistest.make(
    _fails_on_imp_path_that_breaks_workspace_root_imp,
    expect_failure = True,
)

def _fails_on_absolute_imp_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "Absolute paths are not supported")
    return analysistest.end(env)

_fails_on_absolute_imp_test = analysistest.make(
    _fails_on_absolute_imp_impl,
    expect_failure = True,
)

def py_library_import_pathing_test_suite():
    unittest.suite(
        "py_library_import_pathing_test_suite",
        _can_resolve_path_in_workspace_test,
    )

    _py_library(
        name = "__imports_break_out_of_root_lib",
        imports = ["../../../.."],
        tags = ["manual"],
    )

    _fails_on_imp_path_that_breaks_workspace_root_test(
        name = "imp_path_that_breaks_workspace_root",
        target_under_test = ":__imports_break_out_of_root_lib",
    )

    _py_library(
        name = "__imp_path_is_absolute_lib",
        imports = ["/foo"],
        tags = ["manual"],
    )

    _fails_on_absolute_imp_test(
        name = "imp_path_can_not_be_absolute",
        target_under_test = ":__imp_path_is_absolute_lib",
    )
