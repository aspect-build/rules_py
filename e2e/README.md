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

`rules-python-interop` carries both directions of rules_py ↔ rules_python interop in
one module, split by Python version so neither side's toolchains shadow the other's
(see its `MODULE.bazel`): rules_py rules on a rules_python-provisioned 3.11, and
rules_python's consumer rules (`current_py_toolchain`, `py_console_script_binary`,
`py_zipapp_binary`, a pip hub) on rules_py-provisioned interpreters everywhere else.

`rules-python-provider-compat` is separate because it needs a module-wide flag the
workspace above must not carry: its `.bazelrc` turns on the rules_python provider
compatibility layer, so rules_python `py_*` targets can depend on a rules_py `py_library`.
Its `test.sh` asserts the same dependency is rejected with the flag off.

`crossbuild` covers `pep517_native_whl`'s cross-compilation path across the
PEP 517 backends, each with more than one real package so no backend's cross
support rests on a single case: setuptools/distutils C extensions
(`pycross-geohash`, `pycross-psutil`, `pycross-msgpack`, `pycross-setuptools`),
meson-python (`pycross-meson`, `pycross-numpy`), scikit-build-core/CMake
(`pycross-cmake`, `pycross-jdk` — the latter also needing a JDK and a
hermetically vendored Apache Ant), maturin/PyO3 (`pycross-rust`,
`pycross-rpds_py`) and setuptools-rust (`pycross-bcrypt`, `pycross-tiktoken`).
Every case builds for linux/amd64 and linux/arm64; in-suite verification is
structural (`Tag:` metadata, ELF arch of every bundled `.so`), and each case
exports a wheel bundle that CI installs and runs on NATIVE amd64 and arm64
runners — no emulation in the verdict. The suites are isolated from
`e2e/cases` because their hubs need package-specific configuration
(`default_build_dependencies`, pre-build patches, a larger `resource_set`)
that would otherwise leak onto unrelated packages sharing the hub. On a macOS
host, `test.sh` additionally cross-builds `pycross-geohash` for macOS amd64
(a manual target: the platform transition always resolves to os:macos, so
`target_compatible_with` cannot tell hosts apart).

Each isolated workspace points back at repo-root rules_py with
`local_path_override(path = "../..")`.

## How CI drives all of this

`.github/workflows/ci-workflows.yaml` gives every workspace its own test-matrix job.
Each job runs `aspect test //...` first, then its `test.sh` (if it has one):

- `e2e/cases` — `//...` (every shared case) then `cases/test.sh` (aggregates the
  shared-workspace script cases: assert-a-build-fails / need-a-real-`bazel run`).
- `interpreter-runtime-metadata` — `//...` then `test.sh`.
- `rules-python-interop` — `//...` then `test.sh` (the exec-tools version sweep needs a
  top-level `bazel run` under each version flag).
- `interpreter-toolchain-settings`, `interpreter-input-validation` — `//...` runs a
  dumb `build_test` smoke target, then `test.sh` does the real work (config-flag /
  failure-assertion / nested-module checks that can't be `sh_test`s under `//...`).
