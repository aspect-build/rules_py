# py_library DefaultInfo.files regression test (#891)

`py_library` must NOT include transitive sources in `DefaultInfo.files`.
Transitive sources belong exclusively in `PyInfo.transitive_sources`.

## Why this matters

When `DefaultInfo.files` includes the transitive closure, every rule that
consumes a `py_library` via `DefaultInfo` (e.g. filegroups, `select_chain`)
ends up flattening an O(n²) depset — the same sources appear once per level
of the dependency graph. In large workspaces this causes Bazel to OOM during
analysis or action execution.

## History

- PR #221 originally fixed this by removing `transitive = [transitive_srcs]`
  from the `DefaultInfo` constructor in `py_library`.
- Commit `cffaeac` (proto/gRPC WIP) accidentally re-introduced it.
- PR #891 reverted the regression and added this test.

## What the test checks

The analysis test builds a two-level `py_library` chain (`leaf` → `mid`) and
asserts that `mid`'s `DefaultInfo.files` contains only `mid.py`, not
`leaf.py`.
