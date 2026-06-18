# aspect_rules_py — `openai-head-patches-2026.06.16`

This branch carries the OpenAI integration patch stack onto aspect-build `main`.

## Source

- Upstream fork: `tamird/rules_py`
- Source branch: [`openai-integration-2026-06-16`](https://github.com/tamird/rules_py/tree/openai-integration-2026-06-16)
- Local branch: `openai-head-patches-2026.06.16` (pushed to `origin` as `openai-integration-2026-06-16`)
- Rebase target: [`4f164ee8`](https://github.com/aspect-build/rules_py/commit/4f164ee8) — current `origin/main` HEAD (docs: fix misleading debugger support section in README, [#1132](https://github.com/aspect-build/rules_py/pull/1132))

## Rebase result

**This rebase was a clean replay.** `main` advanced by a single docs-only commit since the previous base ([`cb89aa72`](https://github.com/aspect-build/rules_py/commit/cb89aa72)):

| Main commit | Subject |
|-------------|---------|
| [`4f164ee8`](https://github.com/aspect-build/rules_py/commit/4f164ee8) | docs: fix misleading debugger support section in README ([#1132](https://github.com/aspect-build/rules_py/pull/1132)) |

It touches only `README.md`, which the patch stack never modifies, so all **16 patches** replayed with no conflicts and no changes — only their SHAs moved. The stack now forks from `4f164ee8`.

The substantive reconciliation that gives the stack its current shape happened in the two prior rebases (onto `e5142baf` and `cb89aa72`) and still holds — see [Commits modified or no longer necessary](#commits-modified-or-no-longer-necessary). In brief:

- **`#1125` upstreamed `parse_record_path`** (a `csv.reader`-equivalent state machine), so patch #4 (`read wheel metadata with Bazel`) no longer carries that helper and is now **purely e2e test additions**.
- **`#1130` bumped `hermetic_launcher` to 0.0.11**, changing the `./app` launcher binary in OCI image layers; the launcher patches' golden tar-listing snapshots were resolved to the **branch side** (which carries the `launcher_bootstrap.py` / `python_wrapper` files the patches add).

## Carried OpenAI patches (16)

Listed in rebase order (oldest first). Each sits on top of `cb89aa72`.

| # | Local | Subject | Files | Δ |
|---|-------|---------|------:|---|
| 1 | [`66d58a4c`](https://github.com/aspect-build/rules_py/commit/66d58a4c) | feat(uv): declare wheel build memory | 14 | +304/-21 |
| 2 | [`29215f48`](https://github.com/aspect-build/rules_py/commit/29215f48) | fix(uv): keep inactive marker packages valid | 8 | +96/-8 |
| 3 | [`f39a41cc`](https://github.com/aspect-build/rules_py/commit/f39a41cc) | fix(uv): preserve compiler commands | 14 | +576/-173 |
| 4 | [`8eb65e50`](https://github.com/aspect-build/rules_py/commit/8eb65e50) | fix(uv): read wheel metadata with Bazel | 11 | +391/-0 |
| 5 | [`b6e620fa`](https://github.com/aspect-build/rules_py/commit/b6e620fa) | fix(uv): isolate sdist backend imports | 5 | +129/-2 |
| 6 | [`de89a170`](https://github.com/aspect-build/rules_py/commit/de89a170) | fix(py): import from runfiles manifests | 8 | +1134/-1 |
| 7 | [`628d6c6c`](https://github.com/aspect-build/rules_py/commit/628d6c6c) | fix(py): materialize namespace packages | 9 | +558/-162 |
| 8 | [`4b4e3635`](https://github.com/aspect-build/rules_py/commit/4b4e3635) | fix(py): avoid dirname in console scripts | 3 | +19/-2 |
| 9 | [`91659da9`](https://github.com/aspect-build/rules_py/commit/91659da9) | fix(py): preserve PBS prefix from any cwd | 19 | +783/-80 |
| 10 | [`5292470c`](https://github.com/aspect-build/rules_py/commit/5292470c) | refactor(py): avoid per-binary venv targets | 13 | +462/-207 |
| 11 | [`2ae7baec`](https://github.com/aspect-build/rules_py/commit/2ae7baec) | fix(py): preserve wheel target ownership | 35 | +1551/-940 |
| 12 | [`02bf04e2`](https://github.com/aspect-build/rules_py/commit/02bf04e2) | feat(uv): declare built wheel metadata | 25 | +727/-36 |
| 13 | [`7b40186b`](https://github.com/aspect-build/rules_py/commit/7b40186b) | fix(uv): suppress patch backup files | 1 | +62/-8 |
| 14 | [`b669b2d3`](https://github.com/aspect-build/rules_py/commit/b669b2d3) | fix(py): preserve last-wins collisions | 5 | +88/-40 |
| 15 | [`5560c678`](https://github.com/aspect-build/rules_py/commit/5560c678) | fix(py): replace read-only merge entries | 2 | +41/-9 |
| 16 | [`90b73d5a`](https://github.com/aspect-build/rules_py/commit/90b73d5a) | fix(py): own complete namespace merges | 4 | +126/-148 |

Roughly two themes:

- **`uv` wheel/sdist build pipeline** (1–5, 12, 13): build-memory monitoring for `pep517_whl`, compiler-command preservation through sdist native builds, reading wheel metadata via Bazel, declaring built-wheel metadata, marker-package validity, sdist backend import isolation, and patch-backup suppression.
- **`py` venv assembly & launcher** (6–11, 14–16): namespace-package materialization and merge semantics (last-wins collisions, read-only entry replacement, complete-namespace ownership, wheel target ownership), runfiles-manifest imports, PBS-prefix resolution from any cwd, dropping per-binary venv targets, and console-script `dirname` avoidance.

## Commits modified or no longer necessary

**Dropped (1):**

- **`a1bf5f71` fix(py): normalize wheel tree permissions** — landed verbatim on `main` as [#1123](https://github.com/aspect-build/rules_py/pull/1123). After resolving its conflicts to the `main` side the patch was empty, so `git rebase` auto-dropped it. `main`'s `unpack_test.py` is a strict superset: it keeps the permission-normalization assertions and adds compileall/unpack-error coverage ([#1128](https://github.com/aspect-build/rules_py/pull/1128), [#1129](https://github.com/aspect-build/rules_py/pull/1129)).

**Reduced to test-only (2):**

- **#4 `fix(uv): read wheel metadata with Bazel`** — the implementation is in `main` via [#1128](https://github.com/aspect-build/rules_py/pull/1128), and as of this rebase the `parse_record_path` CSV helper is in `main` too via [#1125](https://github.com/aspect-build/rules_py/pull/1125). Both conflicting hunks (`repository.bzl`, `test.bzl`) resolved to `main`. What remains is **only added test coverage `main` lacks** — the `uv-data-purelib` and `uv-plus-version` e2e cases (`+391/-0`, all new files).
- **#13 `fix(uv): suppress patch backup files`** — the `--no-backup-if-mismatch` flag and clean patch-failure handling are in `main` via [#1121](https://github.com/aspect-build/rules_py/pull/1121). The patch now contributes only the backup-suppression test coverage in `unpack_test.py`.

**Reconciled (2):**

- **#10 `refactor(py): avoid per-binary venv targets`** — conflicted with [#1127](https://github.com/aspect-build/rules_py/pull/1127) in `py_image_layer.bzl`. `main` reworked `is_binary` detection to key on providers; resolved to `main`'s version. The patch's extra `DefaultInfo in target` guard was redundant.
- **#11 `fix(py): preserve wheel target ownership`** — conflicted with [#1129](https://github.com/aspect-build/rules_py/pull/1129) in `unpack.py` over the `compile_pyc` block. Merged to keep `main`'s `compileall` return-code check while keeping this patch's de-duplication of the `site_packages` computation.

## Re-running the rebase

```bash
git remote add tamird https://github.com/tamird/rules_py.git
git fetch tamird openai-integration-2026-06-16
git fetch origin main
git checkout -B openai-head-patches-2026.06.16 tamird/openai-integration-2026-06-16
git rebase origin/main
```

Expect conflicts in `uv/private/whl_install/{repository,test}.bzl` (resolve to `main` — it owns `parse_record_path` and the wheel-metadata extraction), and in the OCI golden snapshots under `e2e/cases/**/snapshots/*.yaml` (resolve to the branch side, then regenerate them in CI). Verify the non-e2e tree with:

```bash
bazel build --nobuild //py/... //uv/...
bazel test //uv/private/whl_install:all //py/tools/unpack:unpack_test
```
