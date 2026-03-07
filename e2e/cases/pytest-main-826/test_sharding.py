"""Tests to exercise pytest-shard with Bazel sharding (shard_count >= 3).

Each test is independent so they can be distributed across shards.
The key assertion is that the overall test target passes — meaning the
vendored ShardPlugin correctly partitions tests across shards.
"""

import os


def test_shard_env_vars():
    """Verify Bazel shard environment variables are set when sharding is enabled."""
    # These are set by Bazel when shard_count > 1
    assert "TEST_SHARD_INDEX" in os.environ
    assert "TEST_TOTAL_SHARDS" in os.environ
    assert int(os.environ["TEST_TOTAL_SHARDS"]) == 3


def test_shard_index_in_range():
    """Verify the shard index is within the valid range."""
    idx = int(os.environ["TEST_SHARD_INDEX"])
    total = int(os.environ["TEST_TOTAL_SHARDS"])
    assert 0 <= idx < total


def test_shard_status_file():
    """Verify the shard status file path is provided."""
    assert "TEST_SHARD_STATUS_FILE" in os.environ


def test_alpha():
    """Filler test to ensure enough tests for 3-way sharding."""
    assert True


def test_beta():
    """Filler test to ensure enough tests for 3-way sharding."""
    assert True


def test_gamma():
    """Filler test to ensure enough tests for 3-way sharding."""
    assert True


def test_delta():
    """Filler test to ensure enough tests for 3-way sharding."""
    assert True


def test_epsilon():
    """Filler test to ensure enough tests for 3-way sharding."""
    assert True


def test_zeta():
    """Filler test to ensure enough tests for 3-way sharding."""
    assert True
