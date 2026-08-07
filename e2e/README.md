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

`crossbuild` covers `pep517_native_whl`'s cross-compilation path across five
PEP 517 backends, each with more than one real, popular package so no
backend's cross support rests on a single lucky case: two plain
setuptools/distutils C extensions (`geohash`, `psutil`), `contourpy`
(meson-python), two scikit-build-core/CMake packages (`awkward_cpp`,
`jpype1` — the latter also needing a real Eclipse Temurin JDK and a
hermetically vendored Apache Ant, both fetched directly rather than relying
on rules_java's default remotejdk, which is actually Azul Zulu, or a system
`ant`), two maturin/PyO3 Rust packages (`rpds_py`, `pydantic_core`), and
`bcrypt` (setuptools-rust — a different real-world Rust-in-Python
integration than maturin, with no build-backend value of its own to detect
it by). Every case is built and packaged for linux/amd64 and linux/arm64
from the same amd64 exec host and actually executed — QEMU for the Linux
targets — not just inspected. One more package (`zstandard`) also ships
official prebuilt wheels; its case
diffs our cross-compiled output against theirs byte-for-byte instead of
checking against a hardcoded expected value. It's isolated
rather than a package under `e2e/cases` because its pip hub needs
package-specific configuration (`default_build_dependencies`, a pre-build
patch, a larger `resource_set`) that would otherwise leak onto unrelated
packages sharing the hub — see the module docstring in its `MODULE.bazel`.
On a macOS runner (the `smoke` job, see below) it additionally builds and
runs for arm64/amd64 macOS via the Xcode SDK, executing the amd64 one under
Rosetta 2 — see its `test.sh` for why that half can't just be more
`platform_transition_filegroup` targets under `//...`.

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
