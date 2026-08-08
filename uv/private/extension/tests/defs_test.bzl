"""Unit tests for helpers in defs.bzl"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//uv/private/extension:defs.bzl", "dedupe_shared_installs", "parse_declared_console_script", "quirked_bdists", "shared_install_key")
load("//uv/private/extension:lockfile.bzl", "url_basename")

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

def _quirk(name, version = "", dist_info_name_differs = False):
    """One `uv.package_quirks` tag. An unset `version` is the empty string."""
    return struct(
        name = name,
        version = version,
        dist_info_name_differs = dist_info_name_differs,
    )

_QUIRK_BDISTS = {
    "whl__actioneer__aaa": ("actioneer", "0.0.1"),
    "whl__actioneer__bbb": ("actioneer", "0.0.2"),
    "whl__cowsay__ccc": ("cowsay", "6.0"),
}

def _quirked_bdists_test_impl(ctx):
    env = unittest.begin(ctx)

    # A versioned quirk selects that release's wheels and no others, so a later
    # release built by conforming tooling stops paying for it.
    quirks = quirked_bdists(
        [_quirk("actioneer", version = "0.0.1", dist_info_name_differs = True)],
        _QUIRK_BDISTS,
    )
    asserts.equals(env, ["whl__actioneer__aaa"], sorted(quirks.wheels.keys()))
    asserts.true(env, quirks.wheels["whl__actioneer__aaa"].dist_info_name_differs)
    asserts.equals(env, [], quirks.unmatched)

    # An omitted version applies to every release.
    quirks = quirked_bdists(
        [_quirk("actioneer", dist_info_name_differs = True)],
        _QUIRK_BDISTS,
    )
    asserts.equals(
        env,
        ["whl__actioneer__aaa", "whl__actioneer__bbb"],
        sorted(quirks.wheels.keys()),
    )

    # The tag spells the package however the user does; the lock is normalized.
    quirks = quirked_bdists([_quirk("Actioneer", dist_info_name_differs = True)], _QUIRK_BDISTS)
    asserts.equals(env, 2, len(quirks.wheels))

    # Declaring a quirk for a package no lock resolves is inert rather than an
    # error, so a shared module can record what it knows about the ecosystem.
    quirks = quirked_bdists(
        [
            _quirk("nonesuch", dist_info_name_differs = True),
            _quirk("actioneer", version = "9.9.9", dist_info_name_differs = True),
        ],
        _QUIRK_BDISTS,
    )
    asserts.equals(env, {}, quirks.wheels)
    asserts.equals(env, [("actioneer", "9.9.9"), ("nonesuch", None)], quirks.unmatched)

    # A quirk left at its default selects the wheel but asserts nothing about it.
    quirks = quirked_bdists([_quirk("cowsay")], _QUIRK_BDISTS)
    asserts.false(env, quirks.wheels["whl__cowsay__ccc"].dist_info_name_differs)

    # Two modules declaring the same package agree by union, so a build that
    # pulls in both an internal registry and a public one cannot deadlock on it.
    quirks = quirked_bdists(
        [
            _quirk("actioneer", version = "0.0.1"),
            _quirk("actioneer", version = "0.0.1", dist_info_name_differs = True),
        ],
        _QUIRK_BDISTS,
    )
    asserts.true(env, quirks.wheels["whl__actioneer__aaa"].dist_info_name_differs)

    return unittest.end(env)

quirked_bdists_test = unittest.make(_quirked_bdists_test_impl)

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
        "shared_install_key_tests",
        shared_install_key_test,
    )
    unittest.suite(
        "dedupe_shared_installs_tests",
        dedupe_shared_installs_test,
    )
    unittest.suite(
        "quirked_bdists_tests",
        quirked_bdists_test,
    )
