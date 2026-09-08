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
