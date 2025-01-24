# pytest-shard

This is a fork of [pytest-shard](https://github.com/AdamGleave/pytest-shard) @ [4610a08](https://github.com/AdamGleave/pytest-shard/commit/64610a08dac6b0511b6d51cf895d0e1040d162ad)

## Changes

- The pytest hooks were moved into a class `ShardPlugin`, so that they can be loaded via `pytest.main`
- The sharding strategy was changed to a simple round-robin strategy
  - The hash-bashed strategy was causing unbalanced or empty shards with small test sets
