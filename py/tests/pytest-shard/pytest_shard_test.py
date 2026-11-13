from types import SimpleNamespace
from typing import Any

import pytest

from pytest_shard import ShardPlugin, filter_items_by_shard, positive_int


class FakeOptions:
    def __init__(self, verbose: int) -> None:
        self.verbose = verbose


class FakeConfig:
    """A stand-in for pytest's Config, with just what the plugin reads."""

    def __init__(self, shard_id: int = 0, num_shards: int = 1, verbose: int = 0) -> None:
        self.option = FakeOptions(verbose)
        self._opts = {"shard_id": shard_id, "num_shards": num_shards}

    def getoption(self, name: str) -> int:
        return self._opts[name]


def test_positive_int() -> None:
    assert positive_int(0) == 0
    assert positive_int("7") == 7
    with pytest.raises(ValueError):
        positive_int(-1)


def test_filter_items_are_balanced_and_independent_of_collection_order() -> None:
    items = [SimpleNamespace(nodeid=f"test_{i}") for i in range(30)]
    reversed_items = list(reversed(items))

    for shard_count in (1, 3, 8, 40):
        shards = [filter_items_by_shard(items, i, shard_count) for i in range(shard_count)]
        assert sorted(item.nodeid for shard in shards for item in shard) == sorted(
            item.nodeid for item in items
        )
        assert max(map(len, shards)) - min(map(len, shards)) <= 1
        for shard_id, shard in enumerate(shards):
            assert {item.nodeid for item in shard} == {
                item.nodeid
                for item in filter_items_by_shard(reversed_items, shard_id, shard_count)
            }


def test_modifyitems_filters_in_place() -> None:
    items = [SimpleNamespace(nodeid=f"test_{i}") for i in range(6)]
    expected = filter_items_by_shard(items, 1, 2)
    ShardPlugin.pytest_collection_modifyitems(FakeConfig(1, 2), items)
    assert items == expected


def test_modifyitems_shard_id_out_of_range() -> None:
    with pytest.raises(ValueError):
        ShardPlugin.pytest_collection_modifyitems(FakeConfig(2, 2), [])


def test_report_collectionfinish() -> None:
    items: list[Any] = [SimpleNamespace(nodeid="t1"), SimpleNamespace(nodeid="t2")]
    assert ShardPlugin.pytest_report_collectionfinish(FakeConfig(), items) == (
        "Running 2 items in this shard"
    )

    # Verbose mode with multiple shards lists the node ids.
    msg = ShardPlugin.pytest_report_collectionfinish(
        FakeConfig(num_shards=2, verbose=1), items
    )
    assert msg == "Running 2 items in this shard: t1, t2"
