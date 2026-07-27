"""Unit tests for helpers in defs.bzl"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":defs.bzl", "dedupe_shared_installs", "parse_declared_console_script", "shared_install_key")
load(":lockfile.bzl", "collect_bdists", "collect_sdists", "normalize_deps", "url_basename")

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

def _normalize_local_source_artifacts_test_impl(ctx):
    env = unittest.begin(ctx)
    wheel_hash = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    sdist_hash = "sha256:fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
    lock_data = {
        "package": [
            {
                "name": "local-wheel",
                "version": "1.0.0",
                "source": {"path": "artifacts/local_wheel-1.0.0-py3-none-any.whl"},
                "wheels": [{
                    "filename": "local_wheel-1.0.0-py3-none-any.whl",
                    "hash": wheel_hash,
                }],
            },
            {
                "name": "local-sdist",
                "version": "2.0.0",
                "source": {"path": "artifacts/local_sdist-2.0.0.tar.gz"},
                "sdist": {"hash": sdist_hash},
            },
            {
                "name": "local-directory",
                "version": "3.0.0",
                "source": {"directory": "packages/local;directory"},
            },
        ],
    }

    _, _, normalized = normalize_deps("proj", lock_data, "/workspace/project")
    wheel_url = "file:///workspace/project/artifacts/local_wheel-1.0.0-py3-none-any.whl"
    sdist_url = "file:///workspace/project/artifacts/local_sdist-2.0.0.tar.gz"
    asserts.equals(env, wheel_url, normalized["package"][0]["wheels"][0]["url"])
    asserts.equals(env, sdist_url, normalized["package"][1]["sdist"]["url"])

    bdist_specs, bdist_table = collect_bdists(normalized)
    asserts.equals(env, {
        "whl__local_wheel__0123456789abcdef": {
            "filename": "local_wheel-1.0.0-py3-none-any.whl",
            "hash": wheel_hash,
            "url": wheel_url,
        },
    }, bdist_specs)
    asserts.equals(env, {
        wheel_url: "@whl__local_wheel__0123456789abcdef//:whl",
    }, bdist_table)

    sdist_specs, sdist_table = collect_sdists("proj", normalized)
    asserts.equals(env, {
        "sdist__local_sdist__fedcba9876543210": {"file": {
            "hash": sdist_hash,
            "url": sdist_url,
        }},
    }, sdist_specs)
    asserts.equals(env, {
        "sdist_build__proj__local_sdist__2_0_0": "@sdist__local_sdist__fedcba9876543210//file",
    }, sdist_table)
    return unittest.end(env)

normalize_local_source_artifacts_test = unittest.make(
    _normalize_local_source_artifacts_test_impl,
)

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

def _install_cfg(
        whls,
        exclude_glob = [],
        sbuild = None,
        post_install_patches = [],
        extra_deps = [],
        extra_data = []):
    return struct(
        whls = whls,
        exclude_glob = exclude_glob,
        sbuild = sbuild,
        post_install_patches = post_install_patches,
        extra_deps = extra_deps,
        extra_data = extra_data,
    )

def _shared_install_key_test_impl(ctx):
    env = unittest.begin(ctx)

    ordered = {
        "demo-1.0-cp311-cp311-manylinux.whl": "@whl__demo__aaa//:whl",
        "demo-1.0-py3-none-any.whl": "@whl__demo__bbb//:whl",
    }
    reversed_order = {
        "demo-1.0-py3-none-any.whl": "@whl__demo__bbb//:whl",
        "demo-1.0-cp311-cp311-manylinux.whl": "@whl__demo__aaa//:whl",
    }

    key = shared_install_key(_install_cfg(ordered))

    # Same content across lock universes collapses to one repo.
    asserts.equals(env, key, shared_install_key(_install_cfg(ordered)))

    # Wheel order is significant; reversed candidates are not interchangeable.
    asserts.equals(env, False, key == shared_install_key(_install_cfg(reversed_order)))

    # exclude_glob changes the generated install and must split the identity.
    asserts.equals(
        env,
        False,
        key == shared_install_key(_install_cfg(ordered, exclude_glob = ["**/*.pyi"])),
    )

    # Project-local inputs are never shareable.
    asserts.equals(env, None, shared_install_key(_install_cfg(ordered, sbuild = "@sdist_build__x//:whl")))
    asserts.equals(env, None, shared_install_key(_install_cfg(ordered, post_install_patches = ["//:demo.patch"])))
    asserts.equals(env, None, shared_install_key(_install_cfg(ordered, extra_deps = ["//:extra"])))
    asserts.equals(env, None, shared_install_key(_install_cfg(ordered, extra_data = ["//:data.txt"])))

    return unittest.end(env)

shared_install_key_test = unittest.make(_shared_install_key_test_impl)

def _dedupe_shared_installs_test_impl(ctx):
    env = unittest.begin(ctx)

    cowsay = {"cowsay-6.1-py3-none-any.whl": "@whl__cowsay__x//:whl"}
    numpy = {"numpy-2.0-cp311-cp311-manylinux.whl": "@whl__numpy__y//:whl"}
    install_cfgs = {
        # First lock universe: canonical for cowsay.
        "whl_install__alpha__cowsay__6_1": _install_cfg(cowsay),
        # Second lock universe: identical cowsay collapses onto alpha.
        "whl_install__beta__cowsay__6_1": _install_cfg(cowsay),
        # Distinct package survives untouched.
        "whl_install__beta__numpy__2_0": _install_cfg(numpy),
        # Source-built install is never shareable, even with matching wheels.
        "whl_install__gamma__cowsay__6_1": _install_cfg(cowsay, sbuild = "@sdist_build__gamma//:whl"),
    }

    remap = dedupe_shared_installs(install_cfgs)

    # Only the duplicate shareable install is remapped, onto the first seen.
    asserts.equals(env, {"whl_install__beta__cowsay__6_1": "whl_install__alpha__cowsay__6_1"}, remap)

    # The dropped repo is gone; canonical, distinct, and project-local stay.
    asserts.equals(
        env,
        ["whl_install__alpha__cowsay__6_1", "whl_install__beta__numpy__2_0", "whl_install__gamma__cowsay__6_1"],
        sorted(install_cfgs.keys()),
    )

    return unittest.end(env)

dedupe_shared_installs_test = unittest.make(_dedupe_shared_installs_test_impl)

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
        "normalize_local_source_artifacts_tests",
        normalize_local_source_artifacts_test,
    )
    unittest.suite(
        "shared_install_key_tests",
        shared_install_key_test,
    )
    unittest.suite(
        "dedupe_shared_installs_tests",
        dedupe_shared_installs_test,
    )
