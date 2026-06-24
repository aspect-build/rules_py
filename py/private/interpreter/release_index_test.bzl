"""Tests for PBS release-index parsing and selection."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":release_index.bzl", "find_asset", "parse_sha256sums")

_SHA = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
_RELEASE_NEW = "20260202"
_RELEASE_OLD = "20260101"
_LINUX = "x86_64-unknown-linux-gnu"
_WINDOWS = "x86_64-pc-windows-msvc"

def _retains_every_full_version_test_impl(ctx):
    env = unittest.begin(ctx)
    index = parse_sha256sums("\n".join([
        "{} cpython-3.15.0a1+{}-{}-install_only.tar.gz".format(_SHA, _RELEASE_OLD, _LINUX),
        "{} cpython-3.15.0a2+{}-{}-install_only.tar.gz".format(_SHA, _RELEASE_OLD, _LINUX),
        "{} cpython-3.15.0a1+{}-{}-install_only.tar.gz".format(_SHA, _RELEASE_OLD, _WINDOWS),
    ]), _RELEASE_OLD)

    asserts.equals(
        env,
        ["3.15.0a1", "3.15.0a2"],
        sorted(index["3.15/{}/install_only".format(_LINUX)].keys()),
        "Linux release index should retain both published versions",
    )
    asserts.equals(
        env,
        ["3.15.0a1"],
        sorted(index["3.15/{}/install_only".format(_WINDOWS)].keys()),
        "Windows release index should retain its older companion version",
    )
    return unittest.end(env)

retains_every_full_version_test = unittest.make(_retains_every_full_version_test_impl)

def _selects_newest_version_from_first_release_test_impl(ctx):
    env = unittest.begin(ctx)
    key = "3.15/{}/install_only".format(_LINUX)
    asset = find_asset(
        "3.15",
        _LINUX,
        "install_only",
        [_RELEASE_NEW, _RELEASE_OLD],
        {
            _RELEASE_NEW: {
                key: {
                    "3.15.0a1": {"filename": "new-a1", "sha256": _SHA},
                    "3.15.0a2": {"filename": "new-a2", "sha256": _SHA},
                },
            },
            _RELEASE_OLD: {
                key: {
                    "3.15.0": {"filename": "old-final", "sha256": _SHA},
                },
            },
        },
    )

    asserts.equals(env, _RELEASE_NEW, asset["release_date"])
    asserts.equals(env, "3.15.0a2", asset["full_version"])
    asserts.equals(env, "new-a2", asset["filename"])
    return unittest.end(env)

selects_newest_version_from_first_release_test = unittest.make(_selects_newest_version_from_first_release_test_impl)

def release_index_test_suite():
    unittest.suite(
        "release_index_tests",
        retains_every_full_version_test,
        selects_newest_version_from_first_release_test,
    )
