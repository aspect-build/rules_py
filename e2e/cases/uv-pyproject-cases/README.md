# `uv-pyproject-cases`

Umbrella e2e case for regression coverage of distinct
pyproject.toml / setup.py / setup.cfg shapes that
`pep517_whl/build_helper.py` has to route through correctly.

Each subdirectory pins one real PyPI package via the umbrella
`uv.lock`, forces it through the sdist path with
`[tool.uv].no-binary-package` in `pyproject.toml`, and runs a
smoke `py_test` that imports the built package — the *fact that
the sdist build succeeded* is the assertion.

## Cases

### `cdifflib/` — `cdifflib==1.2.9`

Sdist shape:

- `pyproject.toml` with `[project]` table and
  `build-backend = "setuptools.build_meta"`
- `setup.py` + C extension sources (`_cdifflib.c`, `_cdifflib3.c`)
- `[build-system].requires` lists `setuptools >= 61.0`, `pytest`,
  `ruff`, `twine` — dev/test tooling that the build doesn't
  actually need

What it reproduces: under the upstream "always `python -m build
--no-isolation`" dispatch, `build` *validates* (but does not
install) `[build-system].requires` against the build venv and
aborts with:

```
ERROR Missing dependencies:
    twine
    pytest
    ruff
Error: Build failed!
```

Confirmed locally with `bazel build
//cases/uv-pyproject-cases/cdifflib:test`.

Related fix: zbarsky-openai/rules_py
[`f12313870`](https://github.com/zbarsky-openai/rules_py/commit/f12313870283ca6af44393dc730d1ddb2166dc88)
— "prefer setup.py when pyproject metadata is incomplete". Note
that the *narrowed* form of the dispatch fix on
`stack-20260413--8634d49` (commit `fe23cce`) intentionally **does
not** cover cdifflib's shape: cdifflib's `[project]` table omits
`dependencies` and its `setup.py` has no `install_requires`, so
`_legacy_metadata_conflicts_with_pyproject(...)` returns False and
cdifflib still flows through `python -m build`. The Codex original
(broader) routing is what makes this case pass.

### `pyahocorasick/` — `pyahocorasick==2.2.0`

Sdist shape:

- `setup.py` + `setup.cfg`, **no pyproject.toml**
- Real C extension (`src/pyahocorasick.c`)

What it reproduces: native sdists exercise the full
`pep517_native_whl` action with `cwd=<worktree>` and a compiler
subprocess. Anything path-shaped that `build_helper.py` exports to
that subprocess must survive the cwd change. The upstream form

```python
tmp_root = opts.outdir.lstrip("/") + ".tmp"
```

leaves a *relative* `bazel-out/.../whl.tmp` in `TMP` / `TEMP` /
`TEMPDIR` — valid from the action execroot but not from the
compiler's cwd inside the worktree. In the patch chain that
additionally adds compiler-wrapper scripts (zbarsky-openai
[`5d81044`](https://github.com/zbarsky-openai/rules_py/commit/5d81044ec0a2fbcb8f53a198ef3f8e59161bf95c)),
those wrappers are *also* written under `tmp_root`, so the
wrappers themselves become unreachable when `tmp_root` is
relative.

The companion fix on the same `f12313870` commit swaps to:

```python
tmp_root = path.abspath(opts.outdir) + ".tmp"
```

Constrained to `@platforms//os:linux` to match
`//cases/uv-sdist-native-build`: the host-side cc toolchain
plumbing that lets `setup.py bdist_wheel` actually compile a C
extension is only wired up there in this e2e setup.

## Adding a new case

1. Append the package to the umbrella `pyproject.toml`'s
   `dependencies =` list, pinned at the version that exhibits the
   shape you care about, and list it in `[tool.uv].no-binary-package`
   so uv resolves from sdist. Re-run `uv lock` in this directory.
2. Create `cases/uv-pyproject-cases/<package-name>/`.
3. Add a `BUILD.bazel` with a `py_test` that depends on
   `@pypi_uv_pyproject_cases//<package-name>` and sets `dep_group
   = "uv_pyproject_cases"`. For native sdists also set
   `target_compatible_with = ["@platforms//os:linux"]`.
4. Drop an `__test__.py` that imports the package and exercises
   it enough to prove the wheel built and loaded. The sdist build
   path resolving at all is most of the signal.
5. Update this README with the package's sdist shape, the failure
   mode it reproduces, and the related fix.
