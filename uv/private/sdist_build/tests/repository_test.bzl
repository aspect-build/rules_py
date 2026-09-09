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

_TOOLCHAIN = "@rules_rust//rust/toolchain:current_rust_toolchain"

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

def _rust_wiring_test_impl(ctx):
    env = unittest.begin(ctx)
    wiring = sdist_build_test_util.rust_wiring
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

def _missing_rust_toolchain_test_impl(ctx):
    env = unittest.begin(ctx)
    missing = sdist_build_test_util.missing_rust_toolchain
    maturin = {"build_backend": "maturin"}
    st_rust = {"build_backend": "setuptools.build_meta", "build_requires": ["setuptools-rust>=1.7"]}

    asserts.equals(env, None, missing("r", "", {"build_backend": "mesonpy"}, []), "not Rust: nothing to demand")
    asserts.equals(env, None, missing("r", "@rules_rust//rust/toolchain:current_rust_toolchain", maturin, []), "declared toolchain")
    asserts.equals(env, None, missing("r", "", maturin, ["//tools:my_rust_toolchain"]), "hand-wired toolchains are trusted")
    asserts.equals(
        env,
        None,
        missing("r", "", {"build_backend": "setuptools.build_meta", "build_requires": ["setuptools", "cffi"], "inferred_build_requires": ["setuptools-rust"]}, []),
        "inferred setuptools-rust is a guess (zstandard's optional rust-ext): never grounds to demand a toolchain",
    )

    msg = missing("sdist_build__x__pkg__1_0", "", maturin, [])
    asserts.true(env, msg != None and "its build backend is maturin" in msg and "uv.project(rust_toolchain" in msg, "got: {}".format(msg))
    msg = missing("r", "", st_rust, [])
    asserts.true(env, msg != None and "setuptools-rust is among its declared build requirements" in msg, "got: {}".format(msg))
    return unittest.end(env)

missing_rust_toolchain_test = unittest.make(_missing_rust_toolchain_test_impl)
