"""Unit tests for sdist_build's BUILD-template helpers."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//uv/private/sdist_build:repository.bzl", "sdist_build_test_util")

def _config_settings_attr_test_impl(ctx):
    env = unittest.begin(ctx)
    render = sdist_build_test_util.config_settings_attr

    asserts.equals(env, "", render({}), "unset config_settings must add nothing to the rule call")
    asserts.equals(
        env,
        '\n    config_settings = {\n        "cmake.define.FOO": ["1"],\n        "setup-args": ["-Dblas=none", "-Dlapack=none"],\n    },',
        render({
            "setup-args": ["-Dblas=none", "-Dlapack=none"],
            "cmake.define.FOO": ["1"],
        }),
        "keys render sorted, values as Starlark string lists in declared order",
    )
    asserts.equals(
        env,
        '\n    config_settings = {\n        "quote\\"d": ["back\\\\slash"],\n    },',
        render({'quote"d': ["back\\slash"]}),
        "quotes and backslashes in keys and values must render as valid Starlark literals",
    )
    return unittest.end(env)

config_settings_attr_test = unittest.make(_config_settings_attr_test_impl)

def _env_attr_test_impl(ctx):
    env = unittest.begin(ctx)
    render = sdist_build_test_util.env_attr

    asserts.equals(env, "", render({}), "unset env must add nothing to the rule call")
    asserts.equals(
        env,
        '\n    env = {\n        "CFLAGS": "-DMSG=\\"hi\\"",\n        "JAVA_HOME": "$(JAVABASE)",\n    },',
        render({
            "JAVA_HOME": "$(JAVABASE)",
            "CFLAGS": '-DMSG="hi"',
        }),
        "keys render sorted; quotes in values must render as valid Starlark literals",
    )
    return unittest.end(env)

env_attr_test = unittest.make(_env_attr_test_impl)

def _is_rust_build_test_impl(ctx):
    env = unittest.begin(ctx)
    is_rust = sdist_build_test_util.is_rust_build

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
    asserts.true(
        env,
        is_rust({"build_backend": "setuptools.build_meta", "build_requires": ["setuptools"], "inferred_build_requires": ["setuptools-rust"]}),
        "setuptools-rust inferred from .rs files counts too: it is injected into the build venv",
    )
    asserts.false(env, is_rust({"build_backend": "mesonpy"}), "meson-python is not Rust")
    asserts.false(
        env,
        is_rust({"build_backend": "mesonpy", "inferred_build_requires": ["setuptools-rust"]}),
        "stray .rs files under a non-setuptools backend (numpy) do not make a Rust build",
    )
    asserts.true(
        env,
        is_rust({"build_backend": None, "inferred_build_requires": ["setuptools-rust"]}),
        "a bare setup.py with .rs sources is setuptools-rust",
    )
    asserts.equals(env, "setuptools-rust", sdist_build_test_util.normalize_requirement("Setuptools_Rust>=1.7"))
    return unittest.end(env)

is_rust_build_test = unittest.make(_is_rust_build_test_impl)

def _rust_rule_test_impl(ctx):
    env = unittest.begin(ctx)
    rule = sdist_build_test_util.rust_rule
    asserts.equals(env, "pep517_rust_whl", rule({"build_backend": "maturin"}), "maturin sdists take the Rust flavor")
    asserts.equals(env, "pep517_rust_whl", rule({"build_backend": "setuptools.build_meta", "build_requires": ["setuptools-rust>=1.7"]}))
    asserts.equals(env, None, rule({"build_backend": "mesonpy"}), "everything else stays on pep517_native_whl")
    asserts.equals(env, None, rule(None))
    return unittest.end(env)

rust_rule_test = unittest.make(_rust_rule_test_impl)

def _crate_vendoring_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "https://static.crates.io/crates/ahash/ahash-0.8.11.crate",
        sdist_build_test_util.crate_url("ahash", "0.8.11"),
    )
    crates_io = "registry+https://github.com/rust-lang/crates.io-index"
    ok = {"name": "ahash", "version": "0.8.11", "source": crates_io, "checksum": "e89d"}
    git = {"name": "pyo3-fork", "version": "0.22.0", "source": "git+https://github.com/x/pyo3#abc", "checksum": ""}
    unchecked = {"name": "odd", "version": "1.0.0", "source": crates_io, "checksum": ""}
    asserts.equals(env, [], sdist_build_test_util.unsupported_crate_sources([ok]), "crates.io with a checksum vendors fine")
    asserts.equals(env, '\n    cargo_lock = "@@//pkg:Cargo.lock",', sdist_build_test_util.cargo_lock_attr("@@//pkg:Cargo.lock"))
    asserts.equals(
        env,
        ["pyo3-fork@0.22.0 (git+https://github.com/x/pyo3#abc)", "odd@1.0.0 (" + crates_io + ")"],
        sdist_build_test_util.unsupported_crate_sources([ok, git, unchecked]),
        "git sources and checksum-less entries cannot be vendored hermetically",
    )
    return unittest.end(env)

crate_vendoring_test = unittest.make(_crate_vendoring_test_impl)
