"""Unit tests for helpers in defs.bzl"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":defs.bzl", "parse_declared_console_script", "shared_whl_variant_key")
load(":lockfile.bzl", "url_basename")

def _url_basename_test_impl(ctx):
    env = unittest.begin(ctx)

    # A plain registry wheel URL
    asserts.equals(
        env,
        "markupsafe-3.0.3-cp311-cp311-win_amd64.whl",
        url_basename("https://files.pythonhosted.org/packages/83/8a/4414c03d3f891739326e1783338e48fb49781cc915b2e0ee052aa490d586/markupsafe-3.0.3-cp311-cp311-win_amd64.whl"),
    )

    # An sdist URL
    asserts.equals(
        env,
        "foo-1.0.0.tar.gz",
        url_basename("https://files.pythonhosted.org/packages/ab/cd/foo-1.0.0.tar.gz"),
    )

    # A signed/expiring download link (query string is not part of the name)
    asserts.equals(
        env,
        "foo-1.0.0-py3-none-any.whl",
        url_basename("https://mirror.example.com/foo-1.0.0-py3-none-any.whl?Expires=1700000000&Signature=abc%2Fdef"),
    )

    # A PEP 503 hash fragment (fragment is not part of the name)
    asserts.equals(
        env,
        "foo-1.0.0-py3-none-any.whl",
        url_basename("https://pypi.example.com/simple/foo/foo-1.0.0-py3-none-any.whl#sha256=0123456789abcdef"),
    )

    # Both a query string and a fragment
    asserts.equals(
        env,
        "foo-1.0.0-py3-none-any.whl",
        url_basename("https://mirror.example.com/foo-1.0.0-py3-none-any.whl?token=xyz#sha256=0123456789abcdef"),
    )

    # No directory components after the host
    asserts.equals(
        env,
        "foo-1.0.0-py3-none-any.whl",
        url_basename("https://example.com/foo-1.0.0-py3-none-any.whl"),
    )

    return unittest.end(env)

url_basename_test = unittest.make(_url_basename_test_impl)

def _declared_console_script_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        "tool=package.cli:commands.main",
        parse_declared_console_script("tool", "package.cli:commands.main"),
    )
    asserts.equals(
        env,
        None,
        parse_declared_console_script("tool=other", "package.cli:main"),
        "an equals sign in the script name must not change the encoded assignment",
    )

    return unittest.end(env)

declared_console_script_test = unittest.make(_declared_console_script_test_impl)

def _shared_whl_variant_key_test_impl(ctx):
    env = unittest.begin(ctx)
    whl_target = "@whl__demo__abcdef//file"
    ordered = {
        "demo-1.0-1-py3-none-any.whl": whl_target,
        "demo-1.0-2-py3-none-any.whl": whl_target,
    }
    reversed_order = {
        "demo-1.0-2-py3-none-any.whl": whl_target,
        "demo-1.0-1-py3-none-any.whl": whl_target,
    }
    config = struct(
        exclude_glob = [],
        metadata_directory = "demo-1.0.dist-info",
        post_install_patches = [],
    )

    key = shared_whl_variant_key(config, ordered)
    asserts.equals(env, key, shared_whl_variant_key(config, ordered))
    asserts.equals(env, False, key == shared_whl_variant_key(config, reversed_order))
    asserts.equals(
        env,
        False,
        key == shared_whl_variant_key(struct(
            exclude_glob = ["**/*.pyi"],
            metadata_directory = "demo-1.0.dist-info",
            post_install_patches = [],
        ), ordered),
    )
    asserts.equals(
        env,
        None,
        shared_whl_variant_key(struct(
            exclude_glob = [],
            metadata_directory = "demo-1.0.dist-info",
            post_install_patches = ["//:demo.patch"],
        ), ordered),
    )

    return unittest.end(env)

shared_whl_variant_key_test = unittest.make(_shared_whl_variant_key_test_impl)

def defs_test_suite():
    unittest.suite(
        "url_basename_tests",
        url_basename_test,
    )
    unittest.suite(
        "declared_console_script_tests",
        declared_console_script_test,
    )
    unittest.suite(
        "shared_whl_variant_key_tests",
        shared_whl_variant_key_test,
    )
