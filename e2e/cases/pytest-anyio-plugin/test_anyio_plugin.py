"""Regression test: anyio pytest plugin must be disabled when anyio is installed.

When anyio is a direct or transitive dependency, it auto-registers its pytest
plugin via the pytest11 entry point. Without explicitly disabling it with
'-p no:anyio', the plugin interferes with test collection and execution.
"""


def test_anyio_plugin_is_disabled(pytestconfig):
    """The anyio pytest plugin must not be active in the test session.

    If this test fails with 'anyio pytest plugin is active', the fix is to add
    '-p no:anyio' to the args list in py/private/pytest.py.tmpl.
    """
    plugin = pytestconfig.pluginmanager.get_plugin("anyio")
    assert plugin is None, (
        "anyio pytest plugin is active but should be disabled. "
        "When anyio is installed, it auto-registers via pytest11 entry point "
        "and can interfere with async test collection and execution."
    )
