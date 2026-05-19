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

Fix in tree: `--skip-dependency-check` on the `python -m build`
invocation in `pep517_whl/build_helper.py`. Under `--no-isolation`
we already commit to managing the build venv ourselves, so the
`[build-system].requires` validation step is redundant; skipping
it lets packages that pile unrelated dev tooling into `requires`
build cleanly. Background context for the routing trade-offs is
in [`f12313870`](https://github.com/zbarsky-openai/rules_py/commit/f12313870283ca6af44393dc730d1ddb2166dc88)
— the broader "prefer setup.py" fix this case originally
motivated.

### `pyahocorasick/` — `pyahocorasick==2.2.0`

Sdist shape:

- `setup.py` + `setup.cfg`, **no pyproject.toml**
- Real C extension (`src/pyahocorasick.c`)

What it reproduces: native sdists exercise the full
`pep517_native_whl` action with `cwd=<worktree>` and a compiler
subprocess. Two cooperating fixes from the zbarsky-openai patch
chain make this work end-to-end:

1. [`f12313870`](https://github.com/zbarsky-openai/rules_py/commit/f12313870283ca6af44393dc730d1ddb2166dc88)
   swaps `tmp_root` from a workspace-relative
   `opts.outdir.lstrip("/") + ".tmp"` to
   `path.abspath(opts.outdir) + ".tmp"` so `TMP` / `TEMP` /
   `TEMPDIR` (and the wrapper-script parent dir below) stay valid
   once the build subprocess descends into the worktree.
2. [`5d81044`](https://github.com/zbarsky-openai/rules_py/commit/5d81044ec0a2fbcb8f53a198ef3f8e59161bf95c)
   drops thin compiler-wrapper scripts into
   `tmp_root/.aspect_rules_py_compilers/` and rewrites `CC` /
   `CXX` / `CPP` / `LDSHARED` / `LDCXXSHARED` to point at those
   absolute paths. Needed because `pep517_native_whl` emits
   `env = {"CC": "$(CC)", ...}` and `$(CC)` expands to a
   workspace-relative `external/llvm+/toolchain/gcc` that doesn't
   resolve from inside the worktree.

Without (2), CI fails with:

```
error: command 'external/llvm+/toolchain/gcc' failed: No such file or directory
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
