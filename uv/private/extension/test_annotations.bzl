"""Unit tests for the annotations file parser. See annotations.bzl for the format spec."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":annotations.bzl", "parse_annotations")

_LOCK = {
    "build": ("proj", "build", "1.4.0", "__base__"),
    "cowsay": ("proj", "cowsay", "6.0", "__base__"),
    "setuptools": ("proj", "setuptools", "80.10.2", "__base__"),
}

def _resolve(package):
    return _LOCK.get(package["name"])

def _build_dependencies_test_impl(ctx):
    env = unittest.begin(ctx)
    result = parse_annotations(
        {"package": [{
            "name": "cowsay",
            "build-dependencies": [{"name": "build"}, {"name": "setuptools"}],
        }]},
        _resolve,
    )
    asserts.equals(
        env,
        {_LOCK["cowsay"]: [_LOCK["build"], _LOCK["setuptools"]]},
        result.build_deps,
    )
    asserts.equals(env, {}, result.native)
    return unittest.end(env)

build_dependencies_test = unittest.make(_build_dependencies_test_impl)

def _native_flag_test_impl(ctx):
    env = unittest.begin(ctx)
    result = parse_annotations(
        {"package": [
            {"name": "cowsay", "native": True},
            {"name": "build", "native": False},
            {"name": "setuptools"},
        ]},
        _resolve,
    )
    asserts.equals(
        env,
        {_LOCK["cowsay"]: True, _LOCK["build"]: False},
        result.native,
    )

    # Entries without build-dependencies still get an (empty) build deps
    # record; absent `native` keys leave detection on "auto".
    asserts.false(env, _LOCK["setuptools"] in result.native)
    asserts.equals(env, [], result.build_deps[_LOCK["setuptools"]])
    return unittest.end(env)

native_flag_test = unittest.make(_native_flag_test_impl)

def _unresolvable_package_skipped_test_impl(ctx):
    env = unittest.begin(ctx)

    # Entries that don't resolve against this lockfile are ignored entirely,
    # allowing one annotation file to be shared across several locks.
    result = parse_annotations(
        {"package": [{"name": "not-in-this-lock", "native": True}]},
        _resolve,
    )
    asserts.equals(env, {}, result.build_deps)
    asserts.equals(env, {}, result.native)
    return unittest.end(env)

unresolvable_package_skipped_test = unittest.make(_unresolvable_package_skipped_test_impl)

def _unresolvable_build_dep_drops_entry_test_impl(ctx):
    env = unittest.begin(ctx)

    # A build-dependency that doesn't resolve drops the package's build
    # deps record, but other annotations on the entry are kept.
    result = parse_annotations(
        {"package": [{
            "name": "cowsay",
            "native": True,
            "build-dependencies": [{"name": "not-in-this-lock"}],
        }]},
        _resolve,
    )
    asserts.equals(env, {}, result.build_deps)
    asserts.equals(env, {_LOCK["cowsay"]: True}, result.native)
    return unittest.end(env)

unresolvable_build_dep_drops_entry_test = unittest.make(_unresolvable_build_dep_drops_entry_test_impl)

def annotations_test_suite():
    unittest.suite(
        "annotations_tests",
        build_dependencies_test,
        native_flag_test,
        unresolvable_package_skipped_test,
        unresolvable_build_dep_drops_entry_test,
    )
