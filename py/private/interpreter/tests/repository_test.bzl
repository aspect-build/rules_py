"""Tests for repository.bzl BUILD generation."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//py/private/interpreter:exclude_feature.bzl", "INTERPRETER_FEATURES")
load("//py/private/interpreter:repository.bzl", "repository_testlib")

_PYCACHE_EXCLUDE = 'exclude = ["**/__pycache__/*.pyc*"]'

def _feature_filegroups_exclude_pycache_test_impl(ctx):
    env = unittest.begin(ctx)

    targets, excludes = repository_testlib.feature_filegroups("lib/python3.13", False)

    # One glob per feature, and every one of them ignores bytecode: the
    # distribution ships none, so a pyc under a feature directory was written
    # after fetch and must not become an input of the interpreter filegroups.
    globs = [line for line in targets.splitlines() if "srcs = glob(" in line]
    asserts.equals(env, len(INTERPRETER_FEATURES), len(globs))
    for line in globs:
        asserts.true(env, _PYCACHE_EXCLUDE in line, line)

    # The feature patterns are still carved out of _core.
    asserts.true(env, "lib/python3.13/pydoc_data/**" in excludes)

    # Windows generates no feature filegroups.
    asserts.equals(env, ("", []), repository_testlib.feature_filegroups("lib/python3.13", True))

    return unittest.end(env)

feature_filegroups_exclude_pycache_test = unittest.make(_feature_filegroups_exclude_pycache_test_impl)

def _build_file(abi_flags):
    return repository_testlib.build_file_content(
        major = "3",
        minor = "14",
        micro = "0",
        python_bin = "bin/python3",
        is_macos = False,
        is_windows = False,
        abi_flags = abi_flags,
        releaselevel = "final",
        serial = "0",
    )

def _freethreaded_stdlib_excludes_test_impl(ctx):
    env = unittest.begin(ctx)

    # A free-threaded build's standard library is lib/python3.14t, so the
    # test-suite and feature patterns must name that directory, or CPython's
    # own tests and every optional feature stay in _core.
    content = _build_file("t")
    for pattern in [
        "lib/python3.14t/**/test/**",
        "lib/python3.14t/**/tests/**",
        "lib/python3.14t/pydoc_data/**",
        "lib/python3.14t/tkinter/**",
    ]:
        asserts.true(env, repr(pattern) in content, pattern)
    asserts.false(env, "lib/python3.14/" in content)

    # Only the free-threading flag names the stdlib directory: a debug
    # build's is lib/python3.14 and a free-threaded debug build's is
    # lib/python3.14t.
    for abi_flags, stdlib in [("", "lib/python3.14"), ("d", "lib/python3.14"), ("td", "lib/python3.14t")]:
        content = _build_file(abi_flags)
        asserts.true(env, repr(stdlib + "/**/test/**") in content, abi_flags)
        asserts.true(env, repr(stdlib + "/pydoc_data/**") in content, abi_flags)
        asserts.false(env, "lib/python3.14d" in content, abi_flags)
        asserts.false(env, "lib/python3.14td" in content, abi_flags)
        other = "lib/python3.14/" if stdlib.endswith("t") else "lib/python3.14t/"
        asserts.false(env, other in content, abi_flags)

    return unittest.end(env)

freethreaded_stdlib_excludes_test = unittest.make(_freethreaded_stdlib_excludes_test_impl)

def _fake_path(path, real = None, children = None, exists = True):
    """A repository_ctx path: `real` set means a symlink resolving there."""
    return struct(
        basename = path.rsplit("/", 1)[-1],
        exists = exists,
        is_dir = children != None,
        realpath = real or path,
        readdir = lambda: children or [],
    )

def _find_symlinks_test_impl(ctx):
    env = unittest.begin(ctx)

    # /r is reached through /var -> /private/var, as on macOS: links are
    # judged against the canonical root, not the path the walk started from.
    root_real = "/private/var/r"
    root = _fake_path("/var/r", real = root_real, children = [
        _fake_path("/var/r/bin", real = root_real + "/bin", children = [
            _fake_path("/var/r/bin/python3.11", real = root_real + "/bin/python3.11"),
            _fake_path("/var/r/bin/python", real = root_real + "/bin/python3.11"),
            _fake_path("/var/r/bin/python3-config", real = root_real + "/lib/config/python-config"),
            _fake_path("/var/r/bin/gone", exists = False),
            _fake_path("/var/r/bin/host", real = "/usr/bin/env"),
        ]),
        _fake_path("/var/r/lib", real = root_real + "/lib", children = [
            _fake_path("/var/r/lib/config", real = root_real + "/lib/config", children = [
                _fake_path("/var/r/lib/config/python-config", real = root_real + "/lib/config/python-config"),
            ]),
            # A linked directory is recorded as one link and not walked.
            _fake_path("/var/r/lib/current", real = root_real + "/lib/config", children = [
                _fake_path("/var/r/lib/current/python-config", real = root_real + "/lib/config/python-config"),
            ]),
        ]),
    ])

    asserts.equals(
        env,
        {
            "bin/python": "python3.11",
            "bin/python3-config": "../lib/config/python-config",
            "lib/current": "config",
        },
        repository_testlib.find_symlinks(root),
    )

    return unittest.end(env)

find_symlinks_test = unittest.make(_find_symlinks_test_impl)

def _relative_link_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "python3.11", repository_testlib.relative_link("bin/", "bin/python3.11"))
    asserts.equals(env, "../lib/libpython3.11.so", repository_testlib.relative_link("bin/", "lib/libpython3.11.so"))
    asserts.equals(env, "lib/x", repository_testlib.relative_link("", "lib/x"))
    asserts.equals(env, "../../a", repository_testlib.relative_link("x/y/", "a"))
    return unittest.end(env)

relative_link_test = unittest.make(_relative_link_test_impl)

def _build_file_records_symlinks_test_impl(ctx):
    env = unittest.begin(ctx)
    content = repository_testlib.build_file_content(
        major = "3",
        minor = "14",
        micro = "0",
        python_bin = "bin/python3",
        is_macos = False,
        is_windows = False,
        abi_flags = "",
        releaselevel = "final",
        serial = "0",
        symlinks = {"lib/libpython3.14.so": "libpython3.14.so.1.0", "bin/python3": "python3.14"},
    )

    # Sorted, so the generated BUILD does not depend on readdir order.
    asserts.true(
        env,
        'symlinks = {"bin/python3": "python3.14", "lib/libpython3.14.so": "libpython3.14.so.1.0"},' in content,
        content,
    )
    return unittest.end(env)

build_file_records_symlinks_test = unittest.make(_build_file_records_symlinks_test_impl)

def repository_test_suite():
    unittest.suite(
        "repository_tests",
        feature_filegroups_exclude_pycache_test,
        freethreaded_stdlib_excludes_test,
        find_symlinks_test,
        relative_link_test,
        build_file_records_symlinks_test,
    )
