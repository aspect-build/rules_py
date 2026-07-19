from typing import List, Protocol, Sequence

from _pytest import nodes  # for type checking only


class _OptionGroup(Protocol):
    def addoption(self, *args: str, **kwargs: object) -> None: ...


class _Parser(Protocol):
    def getgroup(self, name: str) -> _OptionGroup: ...


class _Options(Protocol):
    verbose: int


class _Config(Protocol):
    option: _Options

    def getoption(self, name: str) -> int: ...


def positive_int(x: str) -> int:
    value = int(x)
    if value < 0:
        raise ValueError(f"Argument {value} must be positive")
    return value


def filter_items_by_shard(
    items: Sequence[nodes.Node], shard_id: int, num_shards: int
) -> List[nodes.Node]:
    """Computes `items` that should be tested in `shard_id` out of `num_shards` total shards."""
    shards = [i % num_shards for i in range(len(items))]

    new_items = []
    for shard, item in zip(shards, items):
        if shard == shard_id:
            new_items.append(item)
    return new_items


class ShardPlugin:
    @staticmethod
    def pytest_addoption(parser: _Parser) -> None:
        """Add pytest-shard specific configuration parameters."""
        group = parser.getgroup("shard")
        group.addoption(
            "--shard-id",
            dest="shard_id",
            type=positive_int,
            default=0,
            help="Number of this shard.",
        )
        group.addoption(
            "--num-shards",
            dest="num_shards",
            type=positive_int,
            default=1,
            help="Total number of shards.",
        )

    @staticmethod
    def pytest_report_collectionfinish(config: _Config, items: Sequence[nodes.Node]) -> str:
        """Log how many and, if verbose, which items are tested in this shard."""
        msg = f"Running {len(items)} items in this shard"
        if config.option.verbose > 0 and config.getoption("num_shards") > 1:
            msg += ": " + ", ".join([item.nodeid for item in items])
        return msg

    @staticmethod
    def pytest_collection_modifyitems(config: _Config, items: List[nodes.Node]) -> None:
        """Mutate the collection to consist of just items to be tested in this shard."""
        shard_id = config.getoption("shard_id")
        shard_total = config.getoption("num_shards")
        if shard_id >= shard_total:
            raise ValueError(
                f"shard_id = {shard_id} must be less than num_shards = {shard_total}"
            )

        items[:] = filter_items_by_shard(items, shard_id, shard_total)
