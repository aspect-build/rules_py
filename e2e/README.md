# End-to-end testing

`e2e/` is **not** a single Bazel workspace — it's a container of sibling workspaces.
Every immediate subdirectory has its own `MODULE.bazel` and is its own workspace, split
by the one distinction that matters: *does the test share one module graph, or does it
need its own?*

(User-facing usage examples live separately under `//examples`, not here.)

## `cases/` — the generic shared workspace

`e2e/cases/` is the big shared workspace. Most integration tests live here as packages
that participate in its `MODULE.bazel` (via an `setup.MODULE.bazel` fragment or by
reusing shared repos), built by `bazel test //...` from within `e2e/cases`. A few carry
a `test.sh` for failure / `bazel run` assertions. See `cases/README.md`.

## `e2e/<name>/` — isolated workspaces

Every other subdirectory is a self-contained workspace with its own `MODULE.bazel`,
resolving against a *different* module graph on purpose, driven by its own `test.sh`
(nested bazel): `interpreter-runtime-metadata` (a pre-release interpreter),
`interpreter-toolchain-settings` (a conflicting toolchain declaration),
`interpreter-input-validation` (an intentionally-invalid config). The latter two are
config-flag / failure-assertion / nested-module checks that `bazel test //...` can't
express; `interpreter-runtime-metadata` also has ordinary `//...` tests.

Each isolated workspace points back at repo-root rules_py with
`local_path_override(path = "../..")`.

## How CI drives all of this

`.github/workflows/ci-workflows.yaml` gives every workspace its own test-matrix job.
Each job runs `aspect test //...` first, then its `test.sh` (if it has one):

- `e2e/cases` — `//...` (every shared case) then `cases/test.sh` (aggregates the
  shared-workspace script cases: assert-a-build-fails / need-a-real-`bazel run`).
- `interpreter-runtime-metadata` — `//...` then `test.sh`.
- `interpreter-toolchain-settings`, `interpreter-input-validation` — `//...` runs a
  dumb `build_test` smoke target, then `test.sh` does the real work (config-flag /
  failure-assertion / nested-module checks that can't be `sh_test`s under `//...`).
