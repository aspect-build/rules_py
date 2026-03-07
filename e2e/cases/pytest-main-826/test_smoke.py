"""Smoke test verifying the shared pytest_main driver works cross-repo."""

import sys


def test_pytest_is_driver():
    """Verify that pytest is actually driving execution (not a plain script)."""
    assert "pytest" in sys.modules


def test_vendored_shard_plugin_available():
    """Verify the vendored pytest_shard (with ShardPlugin) is importable."""
    from pytest_shard import ShardPlugin

    assert ShardPlugin is not None
