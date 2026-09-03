"""Unit tests for sdist_build's Rust build detection and wiring."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//uv/private/sdist_build:repository.bzl", "rust_build_test_util")

_TOOLCHAIN = "@rules_rust//rust/toolchain:current_rust_toolchain"

def _is_rust_build_test_impl(ctx):
    env = unittest.begin(ctx)
    is_rust = rust_build_test_util.is_rust_build

    asserts.false(env, is_rust(None), "no inspection: nothing to detect")
    asserts.false(env, is_rust({}), "empty inspection: nothing to detect")
    asserts.true(env, is_rust({"build_backend": "maturin"}), "maturin is a Rust backend")
    asserts.true(
        env,
        is_rust({"build_backend": "setuptools.build_meta", "build_requires": ["setuptools", "Setuptools_Rust>=1.7"]}),
        "setuptools-rust in build requirements, whatever its spelling or specifier",
    )
    asserts.false(
        env,
        is_rust({"build_backend": "setuptools.build_meta", "build_requires": ["setuptools", "wheel"]}),
        "plain setuptools is not Rust",
    )
    asserts.false(env, is_rust({"build_backend": "mesonpy"}), "meson-python is not Rust")
    asserts.equals(env, "setuptools-rust", rust_build_test_util.normalize_requirement("Setuptools_Rust>=1.7"))
    return unittest.end(env)

is_rust_build_test = unittest.make(_is_rust_build_test_impl)

def _rust_wiring_test_impl(ctx):
    env = unittest.begin(ctx)
    wiring = rust_build_test_util.rust_wiring
    rust_inspection = {"build_backend": "maturin"}

    off = wiring("", rust_inspection, ["//x:jdk"])
    asserts.equals(env, "", off.load_stmt, "no project rust_toolchain: nothing is wired")
    asserts.equals(env, "", off.target)
    asserts.equals(env, ["//x:jdk"], off.toolchains, "override toolchains pass through untouched")

    not_rust = wiring(_TOOLCHAIN, {"build_backend": "mesonpy"}, [])
    asserts.equals(env, "", not_rust.load_stmt, "a non-Rust backend ignores the project rust_toolchain")
    asserts.equals(env, [], not_rust.toolchains)

    on = wiring(_TOOLCHAIN, rust_inspection, ["//x:jdk", _TOOLCHAIN])
    asserts.true(env, "rust_layer.bzl" in on.load_stmt and "rust_host_sysroot" in on.load_stmt, "load() for the layer rule")
    asserts.true(
        env,
        'rust_host_sysroot(\n    name = "rust_host_sysroot",\n    actual = "{}",\n)'.format(_TOOLCHAIN) in on.target,
        "an exec-configured sysroot layer over the project toolchain; got: " + on.target,
    )
    asserts.equals(
        env,
        [_TOOLCHAIN, ":rust_host_sysroot", "//x:jdk"],
        on.toolchains,
        "toolchain and layer first, override extras after, the toolchain not repeated",
    )
    return unittest.end(env)

rust_wiring_test = unittest.make(_rust_wiring_test_impl)
