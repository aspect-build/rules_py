"""Smoke tests for resolve_wheel_collisions.

Validates the extraction from the former venv.bzl monolith didn't alter
behaviour: single-wheel, namespace-merge, and console-script-collision
code paths produce the expected output shapes.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//py/private/py_venv:virtuals_resolvers.bzl", "resolve_wheel_collisions")

def _mock_ctx(label):
    return struct(label = label)

def _make_wheel(
        site_packages_rfpath,
        metadata_top_levels = [],
        tl_claims = [],
        cs_claims = [],
        regular_roots = [],
        namespace_dirs = [],
        native_roots = [],
        ns_entries = [],
        top_levels = [],
        install_tree = None):
    return struct(
        site_packages_rfpath = site_packages_rfpath,
        metadata_top_levels = metadata_top_levels,
        tl_claims = tl_claims,
        cs_claims = cs_claims,
        regular_roots = regular_roots,
        namespace_dirs = namespace_dirs,
        native_roots = native_roots,
        ns_entries = ns_entries,
        top_levels = top_levels,
        install_tree = install_tree,
    )

def _claim(site_packages, is_ns = False, is_dir = False, is_native = False, ns_entries = []):
    return struct(
        site_packages = site_packages,
        is_ns = is_ns,
        is_dir = is_dir,
        is_native = is_native,
        ns_entries = ns_entries,
    )

def _cs_claim(site_packages, module, func):
    return struct(
        site_packages = site_packages,
        module = module,
        func = func,
    )

def _single_wheel_test_impl(ctx):
    env = unittest.begin(ctx)
    mock_ctx = _mock_ctx(ctx.label)
    wheels = [
        _make_wheel(
            site_packages_rfpath = "external/pypi_foo/site-packages",
            metadata_top_levels = ["foo"],
            tl_claims = [("foo", _claim("external/pypi_foo/site-packages", is_dir = True))],
            cs_claims = [("foo-cli", _cs_claim("external/pypi_foo/site-packages", "foo.cli", "main"))],
            top_levels = ["foo"],
        ),
    ]
    top_level, fully_covered, cs_map, merge_groups, _collisions = resolve_wheel_collisions(
        mock_ctx,
        wheels,
    )
    asserts.equals(env, "external/pypi_foo/site-packages", top_level["foo"])
    asserts.true(env, "external/pypi_foo/site-packages" in fully_covered)
    asserts.equals(env, "foo.cli", cs_map["foo-cli"].module)
    asserts.equals(env, "main", cs_map["foo-cli"].func)
    asserts.equals(env, 0, len(merge_groups))
    return unittest.end(env)

def _namespace_merge_test_impl(ctx):
    env = unittest.begin(ctx)
    mock_ctx = _mock_ctx(ctx.label)
    sp_a = "external/pypi_a/site-packages"
    sp_b = "external/pypi_b/site-packages"
    wheels = [
        _make_wheel(
            site_packages_rfpath = sp_a,
            metadata_top_levels = ["ns"],
            tl_claims = [("ns", _claim(sp_a, is_ns = True, ns_entries = ["ns/sub_a"]))],
            cs_claims = [],
            ns_entries = ["ns/sub_a"],
            namespace_dirs = ["ns"],
            top_levels = ["ns"],
        ),
        _make_wheel(
            site_packages_rfpath = sp_b,
            metadata_top_levels = ["ns"],
            tl_claims = [("ns", _claim(sp_b, is_ns = True, ns_entries = ["ns/sub_b"]))],
            cs_claims = [],
            ns_entries = ["ns/sub_b"],
            namespace_dirs = ["ns"],
            top_levels = ["ns"],
        ),
    ]
    top_level, fully_covered, cs_map, merge_groups, _collisions = resolve_wheel_collisions(
        mock_ctx,
        wheels,
    )
    asserts.equals(env, sp_a, top_level["ns/sub_a"])
    asserts.equals(env, sp_b, top_level["ns/sub_b"])
    asserts.equals(env, 0, len(merge_groups))
    return unittest.end(env)

def _console_script_collision_test_impl(ctx):
    env = unittest.begin(ctx)
    mock_ctx = _mock_ctx(ctx.label)
    sp_a = "external/pypi_a/site-packages"
    sp_b = "external/pypi_b/site-packages"
    wheels = [
        _make_wheel(
            site_packages_rfpath = sp_a,
            metadata_top_levels = [],
            tl_claims = [],
            cs_claims = [("tool", _cs_claim(sp_a, "pkg_a.cli", "main"))],
            top_levels = [],
        ),
        _make_wheel(
            site_packages_rfpath = sp_b,
            metadata_top_levels = [],
            tl_claims = [],
            cs_claims = [("tool", _cs_claim(sp_b, "pkg_b.cli", "main"))],
            top_levels = [],
        ),
    ]
    _, _, cs_map, _, _ = resolve_wheel_collisions(
        mock_ctx,
        wheels,
    )
    asserts.equals(env, "pkg_b.cli", cs_map["tool"].module)
    return unittest.end(env)

_single_wheel_test = unittest.make(_single_wheel_test_impl)
_namespace_merge_test = unittest.make(_namespace_merge_test_impl)
_console_script_collision_test = unittest.make(_console_script_collision_test_impl)

def virtuals_resolvers_test_suite(name):
    unittest.suite(
        name,
        _single_wheel_test,
        _namespace_merge_test,
        _console_script_collision_test,
    )
