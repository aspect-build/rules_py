# `uv-pyproject-cases`

Umbrella e2e case for regression coverage of distinct
pyproject.toml / setup.py / setup.cfg shapes that
`pep517_whl/build_helper.py` has to route through correctly.

Each subdirectory pins one real PyPI package via the umbrella
`uv.lock`, forces it through the sdist path with
`[tool.uv].no-binary-package`, and runs a smoke `py_test` that
imports the built package — the *fact that the sdist build
succeeded* is the assertion. Per-case BUILD.bazel files are the
source of truth for the sdist shape, the failure mode without the
fix, the fix in tree, and why the version pin is load-bearing.

## Cases

- [`cdifflib/`](cdifflib/BUILD.bazel) — `cdifflib==1.2.9`. Covers
  packages with unrelated dev tooling in `[build-system].requires`
  that `python -m build --no-isolation` would otherwise reject.
- [`pyahocorasick/`](pyahocorasick/BUILD.bazel) — `pyahocorasick==2.2.0`.
  Covers native sdists (setup.py + setup.cfg, no pyproject.toml,
  real C extension) routed through `pep517_native_whl`. Linux-only.

## Adding a new case

1. Append the package to the umbrella `pyproject.toml`'s
   `dependencies =` list, pinned at the version that exhibits the
   shape you care about, and list it in
   `[tool.uv].no-binary-package` so uv resolves from sdist. Re-run
   `uv lock` in this directory.
2. Create `cases/uv-pyproject-cases/<package-name>/` with a
   `BUILD.bazel` declaring a `py_test` on
   `@pypi_uv_pyproject_cases//<package-name>` with
   `dep_group = "uv_pyproject_cases"`. For native sdists also set
   `target_compatible_with = ["@platforms//os:linux"]`. Capture the
   sdist shape, the failure mode without the fix, the fix in tree,
   and the rationale for the version pin in a leading comment block
   — that comment is the case's canonical documentation.
3. Drop an `__test__.py` that asserts the installed version via
   `importlib.metadata.version("<pkg>")` (so a stale lockfile can't
   silently retarget the case), imports the package, and exercises
   enough of it to prove the wheel built and loaded.
