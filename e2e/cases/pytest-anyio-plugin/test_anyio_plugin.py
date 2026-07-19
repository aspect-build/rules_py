"""Regression test: disabling the anyio pytest plugin via the args attribute.

When anyio is a direct or transitive dependency, it auto-registers its pytest
plugin via the pytest11 entry point. Without opting out, the plugin can
interfere with test collection and execution (e.g. when combined with other
async frameworks or when async tests are not intended to run under anyio).

To disable it, pass the opt-out flag through the Bazel args attribute:

    py_pytest_test(
        name = "my_test",
        args = ["-p", "no:anyio"],
        deps = ["@pypi//anyio", "@pypi//pytest"],
        ...
    )

rules_py forwards Bazel's args to pytest via sys.argv, so this is equivalent
to running `pytest -p no:anyio` on the command line.
"""

import pytest


def test_anyio_plugin_is_disabled(pytestconfig: pytest.Config) -> None:
    """Verify anyio plugin is not active when opted out via args = ["-p", "no:anyio"].

    Without the opt-out, get_plugin("anyio") returns the anyio.pytest_plugin
    module. With it, the plugin is blocked before registration and returns None.
    """
    plugin = pytestconfig.pluginmanager.get_plugin("anyio")
    assert plugin is None, (
        "anyio pytest plugin is active. "
        "Add args = [\"-p\", \"no:anyio\"] to your py_test to disable it."
    )
