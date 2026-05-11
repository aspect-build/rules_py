"""Tests for pep508_evaluate.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":defs.bzl", "MARKER_ENV_ALIASES")
load(":pep508_evaluate.bzl", "evaluate")

_LINUX_ENV = {
    "platform_machine": "x86_64",
    "python_full_version": "3.11.0",
    "python_version": "3.11",
    "sys_platform": "linux",
}

_WINDOWS_ENV = {
    "platform_machine": "x86_64",
    "python_full_version": "3.11.0",
    "python_version": "3.11",
    "sys_platform": "win32",
}

_AARCH64_ENV = {
    "platform_machine": "aarch64",
    "python_full_version": "3.11.0",
    "python_version": "3.11",
    "sys_platform": "linux",
    "_aliases": MARKER_ENV_ALIASES,
}

_X86_64_ENV = {
    "platform_machine": "x86_64",
    "python_full_version": "3.11.0",
    "python_version": "3.11",
    "sys_platform": "linux",
    "_aliases": MARKER_ENV_ALIASES,
}

def _evaluate_test_impl(ctx):
    env = unittest.begin(ctx)

    # Simple equality on sys_platform
    asserts.true(env, evaluate("sys_platform == 'linux'", env = _LINUX_ENV))
    asserts.false(env, evaluate("sys_platform == 'win32'", env = _LINUX_ENV))

    # Inequality
    asserts.true(env, evaluate("sys_platform != 'win32'", env = _LINUX_ENV))
    asserts.false(env, evaluate("sys_platform != 'linux'", env = _LINUX_ENV))

    # 'in' operator
    asserts.true(env, evaluate("'linux' in sys_platform", env = _LINUX_ENV))
    asserts.false(env, evaluate("'linux' in sys_platform", env = _WINDOWS_ENV))

    # 'not in' operator
    asserts.true(env, evaluate("'win32' not in sys_platform", env = _LINUX_ENV))
    asserts.false(env, evaluate("'linux' not in sys_platform", env = _LINUX_ENV))

    # Version comparisons
    asserts.true(env, evaluate("python_version >= '3.10'", env = _LINUX_ENV))
    asserts.false(env, evaluate("python_version >= '3.12'", env = _LINUX_ENV))
    asserts.true(env, evaluate("python_full_version < '3.12.0'", env = _LINUX_ENV))
    asserts.false(env, evaluate("python_full_version < '3.10.0'", env = _LINUX_ENV))

    # 'and' / 'or' combinations
    asserts.true(env, evaluate("sys_platform == 'linux' and python_version >= '3.10'", env = _LINUX_ENV))
    asserts.false(env, evaluate("sys_platform == 'linux' and python_version >= '3.12'", env = _LINUX_ENV))
    asserts.true(env, evaluate("sys_platform == 'win32' or sys_platform == 'linux'", env = _LINUX_ENV))
    asserts.false(env, evaluate("sys_platform == 'win32' or sys_platform == 'darwin'", env = _LINUX_ENV))

    # 'not' operator
    asserts.true(env, evaluate("sys_platform != 'emscripten' and sys_platform != 'win32'", env = _LINUX_ENV))
    asserts.false(env, evaluate("sys_platform != 'emscripten' and sys_platform != 'win32'", env = _WINDOWS_ENV))

    # Empty marker evaluates to True
    asserts.true(env, evaluate("", env = _LINUX_ENV))

    # Nested parentheses
    asserts.true(env, evaluate("((sys_platform == 'linux'))", env = _LINUX_ENV))
    asserts.true(env, evaluate("((sys_platform == 'linux') and (platform_machine == 'x86_64')) or sys_platform == 'win32'", env = _LINUX_ENV))

    # Identifier immediately followed by ')'
    asserts.true(env, evaluate("('linux' in sys_platform)", env = _LINUX_ENV))
    asserts.true(env, evaluate("('win32' not in sys_platform)", env = _LINUX_ENV))
    asserts.true(env, evaluate("(python_version >= '3.10' and 'linux' in sys_platform)", env = _LINUX_ENV))

    # Architecture alias normalization (decide_marker populates _aliases so
    # Python-spelled arch names match Bazel-spelled platform_machine values).
    asserts.true(env, evaluate("platform_machine == 'arm64'", env = _AARCH64_ENV))
    asserts.true(env, evaluate("'arm64' == platform_machine", env = _AARCH64_ENV))
    asserts.true(env, evaluate("platform_machine == 'aarch64'", env = _AARCH64_ENV))
    asserts.false(env, evaluate("platform_machine == 'arm64'", env = _X86_64_ENV))
    asserts.true(env, evaluate("platform_machine == 'amd64'", env = _X86_64_ENV))
    asserts.true(env, evaluate("platform_machine == 'x64'", env = _X86_64_ENV))
    asserts.true(env, evaluate("platform_machine != 'arm64'", env = _X86_64_ENV))

    return unittest.end(env)

evaluate_test = unittest.make(
    _evaluate_test_impl,
)

def pep508_evaluate_test_suite():
    unittest.suite(
        "pep508_evaluate_tests",
        evaluate_test,
    )
