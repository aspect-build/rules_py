# pytest-shard

This is a fork of [pytest-shard](https://github.com/AdamGleave/pytest-shard) @ [4610a08](https://github.com/AdamGleave/pytest-shard/commit/64610a08dac6b0511b6d51cf895d0e1040d162ad)

## Changes

- The pytest hooks were moved into a class `ShardPlugin`, so that they can be loaded via `pytest.main`
- The sharding strategy ranks tests by the SHA-256 digest of their node ID, then assigns them round-robin
  - This keeps shard sizes balanced while making shard membership independent of collection order
  - The previous hash-based assignment could produce unbalanced or empty shards with small test sets
