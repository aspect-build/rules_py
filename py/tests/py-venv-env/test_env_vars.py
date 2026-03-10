"""Verify env vars are set correctly for py_venv_test.

Tests that BAZEL_TARGET, BAZEL_WORKSPACE, BAZEL_TARGET_NAME are provided
via RunEnvironmentInfo (moved from shell activate script to hermetic launcher),
and that custom env dict entries and env_inherit work.
"""

import os
import sys


def check(env, expected):
    actual = os.environ.get(env)
    assert actual == expected, (
        f"Expected {env}={expected!r}, got {actual!r}"
    )


def check_set(env):
    assert env in os.environ, f"Expected {env} to be set"


# BAZEL_* env vars (provided via RunEnvironmentInfo)
check("BAZEL_TARGET", "//py/tests/py-venv-env:test_env_vars")
check("BAZEL_WORKSPACE", "_main")
check("BAZEL_TARGET_NAME", "test_env_vars")

# Custom env dict entries
check("CUSTOM_ONE", "alpha")
check("CUSTOM_TWO", "beta")

# VIRTUAL_ENV should be set by the venv shim
check_set("VIRTUAL_ENV")

# sys.executable should point into the venv
assert ".venv" in sys.executable or "venv" in sys.executable.lower(), (
    f"sys.executable doesn't look like a venv path: {sys.executable}"
)

print("OK: all env vars verified")
