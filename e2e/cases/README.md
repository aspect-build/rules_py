# e2e/cases — the shared integration-test workspace

This directory is a Bazel workspace (`MODULE.bazel` lives here). It holds every
integration test that can share **one** module graph. Each immediate subdirectory is a
test case; sibling directories of `e2e/cases/` (e.g.
`e2e/interpreter-runtime-metadata`) are *separate* isolated workspaces — see
`../README.md`.

## How cases participate

A case joins this workspace either by:

- providing an `setup.MODULE.bazel` fragment that `MODULE.bazel` pulls in with
  `include("//<name>:setup.MODULE.bazel")` — used when the case needs its own pip/uv
  hub, toolchain, or `uv.override_package`; or
- simply reusing repos other fragments already declare (no fragment of its own).

Everything here is built and run by the wildcard:

```sh
bazel test //...
```

## Cases with a `test.sh`

A few cases ship a `cases/<case>/test.sh` because they can't be an `sh_test` under
`//...` — they assert a build **failure** or need a real top-level `bazel run`:
`hermetic-launcher-1116`, `patch-failure`, `pbs-cc-toolchain`,
`uv-invalid-build-overrides`, `uv-patched-topology-change`. They still resolve against
*this* workspace. `cases/test.sh` is the aggregator that runs every `cases/*/test.sh`;
CI runs it on the `e2e/cases` matrix job alongside `bazel test //...` (see
`.github/workflows/ci-workflows.yaml`).

## Adding a case

Drop it under `e2e/cases/<name>/`. If it needs its own hub/toolchain, add
`e2e/cases/<name>/setup.MODULE.bazel` and a matching
`include("//<name>:setup.MODULE.bazel")` line in `MODULE.bazel`.

## Snapshots

`snapshots/` holds checked-in copies of generated repo-rule output, pinned via the
`//:snapshots` `write_source_files` target. Update after an intentional change with
`bazel run //:snapshots`.
