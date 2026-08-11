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

## What the tests check

The analysis test builds a two-level `py_library` chain (`leaf` → `mid`) and
asserts that `mid`'s `DefaultInfo.files` contains only `mid.py`, not
`leaf.py`.

`srcs_leak_test` is a runtime mirror of the repro reported against 1.10.0:
a `py_library` (`:top`) lists another `py_library` (`:__mid_lib`) in its
`srcs`, so any srcs expansion — aspects reading `ctx.rule.files.srcs`
(rules_mypy), genrule `$(SRCS)` — pulls in mid's `DefaultInfo.files`. A
genrule writes that expansion to a manifest and the test asserts it holds
exactly `app.py` and `mid.py`, never the transitively-reachable `leaf.py`.
In the original report the leaked file was a vendored `typing_extensions.py`,
which made mypy fail with `This file shadows library module
"typing_extensions"`.
