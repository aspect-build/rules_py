from dataclasses import dataclass

import pytest

from pytest_shard import ShardPlugin, filter_items_by_shard, positive_int


@dataclass(frozen=True)
class FakeItem:
    nodeid: str


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


def test_filter_items_round_robin() -> None:
    items = list(range(10))
    assert filter_items_by_shard(items, 0, 3) == [0, 3, 6, 9]
    assert filter_items_by_shard(items, 1, 3) == [1, 4, 7]
    assert filter_items_by_shard(items, 2, 3) == [2, 5, 8]

    # Every item lands in exactly one shard.
    assert sorted(
        i for s in range(3) for i in filter_items_by_shard(items, s, 3)
    ) == items

    assert filter_items_by_shard(items, 0, 1) == items
    assert filter_items_by_shard([], 0, 3) == []

    # More shards than items leaves trailing shards empty.
    assert filter_items_by_shard([0], 1, 2) == []


def test_modifyitems_filters_in_place() -> None:
    items = list(range(6))
    ShardPlugin.pytest_collection_modifyitems(FakeConfig(1, 2), items)
    assert items == [1, 3, 5]


def test_modifyitems_shard_id_out_of_range() -> None:
    with pytest.raises(ValueError):
        ShardPlugin.pytest_collection_modifyitems(FakeConfig(2, 2), [])


def test_report_collectionfinish() -> None:
    items = [FakeItem("t1"), FakeItem("t2")]
    assert ShardPlugin.pytest_report_collectionfinish(FakeConfig(), items) == (
        "Running 2 items in this shard"
    )

    # Verbose mode with multiple shards lists the node ids.
    msg = ShardPlugin.pytest_report_collectionfinish(
        FakeConfig(num_shards=2, verbose=1), items
    )
    assert msg == "Running 2 items in this shard: t1, t2"
