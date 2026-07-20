from types import SimpleNamespace

import pytest

from pytest_shard import ShardPlugin, filter_items_by_shard, positive_int


def fake_config(
    shard_id: int = 0, num_shards: int = 1, verbose: int = 0
) -> SimpleNamespace:
    opts = {"shard_id": shard_id, "num_shards": num_shards}
    return SimpleNamespace(
        getoption=lambda name: opts[name],
        option=SimpleNamespace(verbose=verbose),
    )


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
    ShardPlugin.pytest_collection_modifyitems(fake_config(1, 2), items)
    assert items == [1, 3, 5]


def test_modifyitems_shard_id_out_of_range() -> None:
    with pytest.raises(ValueError):
        ShardPlugin.pytest_collection_modifyitems(fake_config(2, 2), [])


def test_report_collectionfinish() -> None:
    items = [SimpleNamespace(nodeid="t1"), SimpleNamespace(nodeid="t2")]
    assert ShardPlugin.pytest_report_collectionfinish(fake_config(), items) == (
        "Running 2 items in this shard"
    )

    # Verbose mode with multiple shards lists the node ids.
    msg = ShardPlugin.pytest_report_collectionfinish(
        fake_config(num_shards=2, verbose=1), items
    )
    assert msg == "Running 2 items in this shard: t1, t2"
