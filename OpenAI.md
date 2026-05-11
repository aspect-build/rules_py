# aspect_rules_py — `openai_patches-robot-2026.05.11`

This branch is a port of the OpenAI [`v1.11.1-monorepo-patch-stack-20260413`](https://github.com/zbarsky-openai/rules_py/tree/openai/v1.11.1-monorepo-patch-stack-20260413) patch stack onto the v2-alpha `main`.

Upstream main has diverged substantially from v1.11.1 (rename of `py_binary.bzl` → `py_venv_exec.bzl`, graduation of `py/unstable` and `uv/unstable` to stable, removal of the legacy Rust venv/unpack tooling, rename of the `venv` flag and attribute to `dep_group`, removal of the dead `lib_mode`/`whl_mode` machinery, removal of the `:whl` alias). Some patches needed adaptation; a few could not be applied.

## Source

- Upstream fork: `zbarsky-openai/rules_py`
- Source branch: `openai/v1.11.1-monorepo-patch-stack-20260413`
- Base of the patch stack: tag `v1.11.1`
- Cherry-pick base in this repo: `82aafb6` (`chore: remove dead pre-commit comments and document adder fixture (#1020)`)

## Remaining OpenAI patches (5)

Listed in cherry-pick order (oldest first). Each row maps the new local commit to the original commit on the upstream fork, and to the corresponding aspect-build/rules_py PR (if one has been opened — many have not been upstreamed yet).

| # | Local | Upstream | aspect-build PR | Subject |
|---|-------|----------|-----------------|---------|
| 1 | `433d6f2` | `f123138` | [#1030](https://github.com/aspect-build/rules_py/pull/1030) (open, alternative implementation — see note) | fix(sdist): prefer setup.py when pyproject metadata is incomplete |
| 2 | `fceb433` | `9c1e4de` | [#1032](https://github.com/aspect-build/rules_py/pull/1032) | fix(uv): preserve wheel metadata and expose dist_info |
| 3 | `f0f1bbe` | `5d81044` | [#1004](https://github.com/aspect-build/rules_py/pull/1004) (merged, possible solution path — see note) | fix(uv): wrap sdist compilers to strip unsupported debug flags |
| 4 | `e6c3bc2` | `ecd1eb6` | [#1010](https://github.com/aspect-build/rules_py/pull/1010) (open, upstreaming) | fix(py): reset Python flags on data edges |
| 5 | `8d8e7e5` | `8d8371f` | — | fix(uv): require an explicit venv for target compatibility |

**Note:** Row 1 (`433d6f2`, "prefer setup.py when pyproject metadata is incomplete") is the cherry-pick of upstream `f123138`. [#1030](https://github.com/aspect-build/rules_py/pull/1030) is an open PR that reimplements the same fix differently (still in `uv/private/pep517_whl/build_helper.py`) and adds e2e coverage under `e2e/cases/uv-pyproject-cases/`. Keep the cherry-pick on this branch until #1030 lands; drop it on the next rebase once #1030 is merged.

**Note:** Row 3 (`f0f1bbe`, "wrap sdist compilers to strip unsupported debug flags") does not yet have a dedicated upstream PR, but [#1004](https://github.com/aspect-build/rules_py/pull/1004) (merged 2026-05-14 as `edf46ec`) is a possible solution path. Its new `pep517_native_whl(toolchains = ..., env = ...)` plumbing exposes a way to swap in a different CC toolchain via `uv.override_package(toolchains = ...)`, which could host a filter-aware variant and obviate the per-action Python wrappers that currently strip `-fdebug-default-version=4` from `CC`/`CXX`/`MPICC`. #1004 itself doesn't ship that filter — porting row 3 onto it means writing a small CC-wrapping toolchain (or a `cc_toolchain_alias` + `env = {"CC": "..."}` that points at the existing `_compiler_env` wrappers) and dropping it in via `uv.override_package(toolchains = [...])`. Keep row 3 as-is until that port is written; drop the in-tree wrappers in `pep517_whl/build_helper.py` once a downstream override is in place.

## Resolved against rules_py `main` (16)

Patches from the upstream stack that are not carried on this branch — already merged to `main` (directly or via a renamed/equivalent PR), closed upstream, obsoleted by main's own evolution, no longer supportable against current `main`, or touching code that main has since deleted. Together with the 5 remaining patches, this accounts for all 21 commits on the upstream patch stack ([`v1.11.1..openai/v1.11.1-monorepo-patch-stack-20260413`](https://github.com/aspect-build/rules_py/compare/main...zbarsky-openai:rules_py:openai/v1.11.1-monorepo-patch-stack-20260413)).

### Already implemented on `main`

- `22c7d34` — fix(py): deconflict generated helper venv target names — superseded by [aspect-build/rules_py#983](https://github.com/aspect-build/rules_py/pull/983) (`d3e8aa5`)
  - Upstream renamed the auto-generated helper venv from `{name}.venv` to `{name}._venv`.
  - HEAD already avoids the collision: `py_binary_with_venv` (in `py/private/py_venv/py_venv.bzl`) generates `_{name}.venv` for the private helper, only using `{name}.venv` when `expose_venv = True`.

- `233161e` — fix(sdist): build helper uses py_binary — superseded by [aspect-build/rules_py#981](https://github.com/aspect-build/rules_py/pull/981) (`afa4418`)
  - Upstream switched `py_venv_binary` → `py_binary_rule` for the sdist build helper.
  - HEAD already uses the plain `py_binary` macro (which routes through `py_venv_exec`) for this helper, matching the patch's intent (no venv-shaped wrapping).

- `3431c52` — fix(sdist): capture setup.py output during configure — superseded by [aspect-build/rules_py#888](https://github.com/aspect-build/rules_py/pull/888) (`28c9e13`, "tweak(sdist_configure): suppress setup.py stdout/stderr unless eval fails", landed 2026‑03‑20, ~3 weeks before this patch was authored)
  - The patch wraps `exec(compile(content, "setup.py", "exec"), globs)` in `uv/private/sdist_configure/detect_native.py::_parse_setup_py_requires` with `contextlib.redirect_stdout(io.StringIO()) / redirect_stderr(io.StringIO())` so stray `print()` calls from `setup.py` don't corrupt the JSON output of the probe.
  - `main` already does the same job one scope up: lines 283-296 build `stdout_tmp = tempfile.TemporaryFile()` / `stderr_tmp` and assign `sys.stdout = stdout_tmp` / `sys.stderr = stderr_tmp` before the `exec()`, restoring in the `finally:` block (and *replaying* `stdout_tmp` to stderr on the failure path for debuggability). The patch's `contextlib.redirect_stdout` is literally a `sys.stdout = ...` swap at the same level, so its inner `StringIO()` shadows main's tempfile for the duration of the `with` block and the tempfile sees nothing.
  - Net effect: redundant, and slightly worse — anything `setup.py` prints lands in the patch's throwaway `StringIO` instead of `stdout_tmp`, so the failure-path replay disappears. Things that bypass **both** fixes (because both operate at the `sys.stdout` level, not file-descriptor 1): `os.write(1, ...)`, `sys.__stdout__.write(...)`, and `subprocess` children inheriting parent fds. An fd-level fix would need `os.dup2`.

### Merged upstream

- `9c967f2` — fix(uv): flush marker identifiers before parentheses — [aspect-build/rules_py#999](https://github.com/aspect-build/rules_py/pull/999) (merged 2026-05-11 as `df07a0f`)
  - Already on `main` before this branch's prior cherry-pick run; never needed to be applied locally and is not present in our commit list.

- `d0c3156` — fix(uv): add explicit default targets to wheel select — [aspect-build/rules_py#995](https://github.com/aspect-build/rules_py/pull/995) (merged 2026-05-11 as `d4b8109`)
  - Was applied as a cherry-pick in an earlier revision of this branch; rebasing onto current `main` dropped it (`patch contents already upstream`).
  - The upstream-merged version is slightly stricter than the cherry-picked one (`fail()` on `if not arms and not default_target` vs. silent return) and is also covered by new tests in `e2e/cases/uv-no-sdist-754/`.
  - One related conflict was resolved during that rebase in `uv/private/whl_install/defs.bzl`, where `fceb433` ("preserve wheel metadata and expose dist_info") also touched `select_chain`'s empty-arms path: kept main's version (it supersedes the patch's contribution to this file).

- `b234542` — fix(uv): recognize generic linux wheel platform tags — [aspect-build/rules_py#996](https://github.com/aspect-build/rules_py/pull/996) (merged 2026-05-11 as `2aff0be`)
  - Was applied as a cherry-pick in an earlier revision of this branch; rebasing onto current `main` dropped it via `git rebase --skip` after the cherry-pick conflicted against the upstream-merged version. Git did not auto-detect the conflict as a no-op because the merged PR includes new test fixtures (`e2e/MODULE.bazel`, `e2e/cases/...`) that the cherry-pick didn't have, but the underlying platform-tag logic in `uv/private/constraints/platform/{defs,macro,test}.bzl` is equivalent.

- `efcf334` — fix(uv): treat abi3 wheels as compatible with newer CPython minors — [aspect-build/rules_py#997](https://github.com/aspect-build/rules_py/pull/997) (merged 2026-05-11 as `623ca13`)
  - Was applied as a cherry-pick in an earlier revision of this branch; rebasing onto current `main` dropped it via `git rebase --skip` after the cherry-pick conflicted against the upstream-merged version. The merged version uses a different (private) shape for the helper (`_compatible_python_tags` defined locally in both `uv/private/whl_install/repository.bzl` and `uv/private/extension/lockfile.bzl`, plus a `source_specificity` tiebreaker for overlapping abi3 wheels) and adds new abi3-coverage e2e cases under `e2e/cases/`; the underlying behavior matches the cherry-pick.
  - One related conflict was resolved during that rebase in `uv/private/extension/lockfile.bzl`, where `fceb433` ("preserve wheel metadata and expose dist_info") had added its own abi3 expansion through the public `compatible_python_tags` exposed by the patch. Kept main's version (the private `_compatible_python_tags` already covers the same expansion); dropped the now-unused `load(..., "compatible_python_tags")` import from `lockfile.bzl`.

- `705abf8` — fix(uv): suppress nonfatal pyc compile warnings — [aspect-build/rules_py#1000](https://github.com/aspect-build/rules_py/pull/1000) (merged 2026-05-11 as `7832c53`)
  - The upstream patch modified the legacy `py/tools/unpack_bin/src/main.rs` (removed by [#975](https://github.com/aspect-build/rules_py/pull/975)); the merged version applies the same `compileall` warning suppression to the new `py/tools/unpack/src/main.rs` (the unpack tool was rewritten in Rust on top of the new Starlark venv assembly).

- `738a7ca` — fix(uv): always keep sdist fallbacks when sources exist — [aspect-build/rules_py#998](https://github.com/aspect-build/rules_py/pull/998) (merged 2026-05-11 as `549193d`)
  - Was applied as a cherry-pick in an earlier revision of this branch; rebasing onto current `main` dropped it (`patch contents already upstream`).
  - The merged PR also tightens the surrounding code path in `uv/private/extension/defs.bzl`: `lock_build_deps == None` now passes `fail_if_missing = sbuild_required` so an absent `default_build_dependencies` only fails when an sbuild is guaranteed to be selected (`no-binary-package` or sdist-only). It also removes the `has_none_any` / `elide_sbuilds_with_anyarch` early-exit and the corresponding `_project_tag` attribute. The patch only addressed the keep-sdist-fallbacks half, so the rest of #998's cleanup ships only via the merge.
  - One related conflict was resolved during that rebase in `uv/private/extension/defs.bzl`, where `fceb433` ("preserve wheel metadata and expose dist_info") had: (a) added the `_merge_build_deps` helper and rewritten the `lock_build_deps`/`build_deps` merge to use it (rather than the post-hoc `sets.to_list(sets.make(...))` dedup), and (b) preserved a now-stale FIXME comment about old `setup.py`-style packages. Took main's choice on both: removed the redundant `sets.to_list(sets.make(...))` dedup line (the `_merge_build_deps` rewrite already dedups) and dropped the FIXME comment block (matching `549193d`).

- `bfe2187` — fix(uv): normalize architecture aliases during marker — [aspect-build/rules_py#1003](https://github.com/aspect-build/rules_py/pull/1003) (merged 2026-05-12 as `4eba200`)
  - Was applied as a cherry-pick in the previous revision of this branch; rebasing onto current `main` dropped it after the cherry-pick conflicted against the upstream-merged version. The merged version is more polished: it hoists the alias table to a module-level `MARKER_ENV_ALIASES` constant (rather than defining `aliases` inline inside `_decide_marker_impl`), adds the uppercase Windows-style `AMD64`/`ARM64` spellings that `platform.machine()` returns there, and ships new e2e regression cases under `e2e/cases/arch-alias-marker/`. After resolving the conflict in `uv/private/markers/defs.bzl` (taking main's `MARKER_ENV_ALIASES` reference) and removing the now-unused inline `aliases` dict, the cherry-pick was an empty no-op and dropped via `git rebase --skip`.

- `63f444e` — fix(sdist): discover Bazel embedded JDK — superseded upstream by [aspect-build/rules_py#1004](https://github.com/aspect-build/rules_py/pull/1004) (merged 2026-05-14 as `edf46ec`, `feat(sdist): generic toolchain env plumbing for pep517_native_whl`)
  - Was applied as a cherry-pick (`0b976e9`) in the previous revision of this branch; dropped from the current rebase now that #1004 has merged.
  - The merged PR replaces the hardcoded toolchain reach inside `pep517_native_whl`'s rule body with generic `ctx.attr.toolchains` + `env`/`$(VAR)` plumbing (mirroring rules_rust's `cargo_build_script`). The targeted Bazel-embedded-JDK discovery workaround in `build_helper.py` is no longer needed — pass `@bazel_tools//tools/jdk:current_java_runtime` via `toolchains` and reference `$(JAVA)` / `$(JAVA_HOME)` / `$(JAVABASE)` in `env` on `uv.override_package`. The PR's `e2e/cases/uv-sdist-jdk-build` regression demonstrates exactly that shape against `jpype1`.
  - One related conflict was resolved during the rebase in `uv/private/pep517_whl/build_helper.py`, where `f0f1bbe` ("wrap sdist compilers to strip unsupported debug flags") had been authored on top of the dropped patch's `_is_valid_java_home` / `_discover_java_home` helpers (they appeared as context in its diff). Took main's choice — kept the compiler-wrapper additions (`_compiler_env`, `_make_compiler_wrapper`, `_override_tool`, `_DEBUG_FLAG`, `_COMPILER_WRAPPER`), dropped the JDK helpers and the `JAVA_HOME` fallback block.

### Closed upstream

- `0009625` — fix(uv): pin sdist build tools to configured Python — [aspect-build/rules_py#1009](https://github.com/aspect-build/rules_py/pull/1009) (closed without merging, 2026-05-13)
  - The patch threads the project-configured Python version into the generated `build_tool` `py_binary` (in `uv/private/extension/defs.bzl` and `uv/private/sdist_build/repository.bzl`) so source builds resolve build backends and build-only deps under the same interpreter the project requested, rather than the exec-config default.
  - Opened upstream verbatim as [#1009](https://github.com/aspect-build/rules_py/pull/1009) by jbedard (from local branch `stack-20260413--0f8a956`), bundled with a new `e2e/cases/uv-sdist-python-version-1004/` regression that pins `python_version = "3.10"` on `uv.project()` and asserts the native C extension shipped in the resulting `python-geohash` wheel carries the `cp310` ABI tag (not the exec-config default `cp311`).
  - **Closed without merging on 2026-05-13** with the comment _"Confirmed this seems no longer necessary"_ — the bug the patch was guarding against does not surface against current `main`. Was applied as a cherry-pick (`0f8a956`) in the previous revision of this branch and removed in the current revision to keep the diff from main minimal. Cherry-pick reference if a real repro shows up later: `0f8a956`, plus the e2e case from PR #1009.

- `0c190be` — fix(py): bake launcher env into entrypoint scripts — [aspect-build/rules_py#993](https://github.com/aspect-build/rules_py/pull/993) (closed without merging, alternative approach preferred)
  - The patch merged user-supplied `env=` values into the `{{PYTHON_ENV}}` substitution in `py/private/py_venv/run.tmpl.sh`, emitting `export KEY="VALUE"` alongside the existing `BAZEL_*` `default_env` so direct exec of the launcher (e.g. inside OCI images, where `RunEnvironmentInfo` is never applied) sees the same env as `bazel run`.
  - PR #993 was closed for two reasons (per the review thread):
    1. **Shell-quoting footguns.** `_dict_to_exports` writes `export %s="%s"` with no escaping, so any value containing `$`, `$(...)`, backticks, backslashes, or quotes is re-interpreted by bash instead of passed literally — breaking the literal-string contract `RunEnvironmentInfo` already guarantees. A follow-up (`aa8afcc`) tried to patch over this with single-quote escaping and a `maybe_resolve_path_like_env_value` shell helper, but both are heuristics that drift further from the literal semantics.
    2. **Consumer no longer needs it.** OpenAI's direct-exec path now goes through `hermetic-launcher` (a real `execve` launcher that reads `RunEnvironmentInfo` and calls `setenv` + `execve` on the venv's `bin/python`, with no shell in the loop), so the upstream consumer dropped its dependency on this PR.
  - **Recommended alternative for the same goal** (direct exec of the launcher outside `bazel run`, using only `RunEnvironmentInfo` + Bazel builtins):
    - For OCI packaging: project `RunEnvironmentInfo.environment` into the image at build time via `rules_oci`'s `oci_image(env = ...)` (or a `tars`/`config` layer fed by an aspect that reads the provider). The OCI runtime then sets the vars at `execve` time with no shell interpolation.
    - For direct exec without an OCI runtime: use an `execve` launcher (the `hermetic-launcher` pattern — see `hermeticbuild/rules_qemu`'s `qemu_binary.bzl:17‑43`). A tiny Go/Rust binary generated by `ctx.actions.expand_template` from the target's `RunEnvironmentInfo` performs `setenv` + `execve` directly — same literal semantics as `bazel run`, no shell quoting issues.

### Obsoleted by modern uv

- `911f0b6` — fix(uv): include root-requested extras in dependency — [aspect-build/rules_py#1001](https://github.com/aspect-build/rules_py/pull/1001) (closed)
  - Adds extra edges to the marker graph in `uv/private/extension/lockfile.bzl::build_marker_graph` for root-level extras declared in the manifest, so optional dependencies selected at the top level participate in resolution/installation.
  - Reads `lock_data["manifest"]["overrides"]`, indexes any entries that carry `extras` by normalized name, then for each matching package spec iterates the requested extras, walks `spec["optional-dependencies"][extra]`, ensures `__base__` is prepended to the dep's own `extra` list, and adds graph edges keyed by the combined (AND-joined) marker via a new `_and_markers` helper.
  - **Reproducible only with a synthetic lockfile.** Probed uv 0.11.13 directly with `tool.uv.override-dependencies = ["requests[socks]"]` in direct, transitive, and workspace shapes; uv consistently inlines the extra into the dependent package's `dependencies` as `{ name = "requests", extra = ["socks"] }`, which the pre-fix graph builder already handles. The bug surfaces only against a hand-edited `uv.lock` where the extra is stripped from the package `dependencies` and present only under `[manifest] overrides` — a shape modern uv does not emit naturally.
  - Defensive-only against older uv versions or future schema changes; dropped from this stack since it isn't load-bearing for current uv users. Cherry-pick reference for anyone resurrecting it: a verified e2e regression test (with the synthetic lockfile) lives at `e2e/cases/uv-manifest-extras/` on branch `stack-20260413--8` alongside commit `8d5b96f` (rewritten authorship of `911f0b6`).

### Unsupported on current `main`

- `a7fd048` — fix(py): resolve path-like env vars in launchers
  - The patch wrapped `_dict_to_exports` in `py/private/py_venv/py_venv_exec.bzl` so that each `export KEY="VALUE"` emitted into the launcher's `{{PYTHON_ENV}}` substitution was run through a shell-side `maybe_resolve_path_like_env_value` helper, turning runfiles-relative values into absolute paths at launcher startup.
  - [aspect-build/rules_py#1011](https://github.com/aspect-build/rules_py/pull/1011) (merged 2026-05-14 as `a1d70f8`, `refactor: move BAZEL_* env vars into RunEnvironmentInfo`) deleted `_dict_to_exports`, the `{{PYTHON_ENV}}` substitution, and the shell-level `export` block in `run.tmpl.sh`. The launcher no longer applies env vars itself — `BAZEL_TARGET` / `BAZEL_WORKSPACE` / `BAZEL_TARGET_NAME` (plus all user-supplied `env = {...}` values) now ride on `RunEnvironmentInfo.environment` and are applied by Bazel at `bazel run` time, not by the shell template.
  - With both `_dict_to_exports` and the shell-side `{{PYTHON_ENV}}` block gone, there is no attachment point on `main` for the patch's payload, and no clean replacement: `RunEnvironmentInfo.environment` values are literal strings, not shell snippets, so a path-resolution helper can't be wired in there without re-introducing a shell layer that #1011 deliberately removed.
  - Was applied as a cherry-pick (`4120e75`, then `823ba99` after rebase onto #1011) in earlier revisions of this branch; dropped on 2026-05-14. The OpenAI consumer's direct-exec path already goes through `hermetic-launcher` (a real `execve` launcher that reads `RunEnvironmentInfo` directly — see closed PR [#993](https://github.com/aspect-build/rules_py/pull/993) above), so the runfiles-path resolution this patch provided is no longer load-bearing.

### Modified deleted Rust tooling

- `3acde7e` — fix(uv): filter Bazel metadata from generated py venvs
  - File removed by [#975](https://github.com/aspect-build/rules_py/pull/975) (legacy Rust venv/unpack tooling — venv assembly moved to Starlark `assemble_venv`).
  - Modifies `py/tools/py/src/venv.rs::populate_venv` to skip `BUILD`, `MODULE.bazel`, `REPO.bazel`, `WORKSPACE`, `WORKSPACE.bazel`, `WORKSPACE.bzlmod` files.
  - Cannot be ported as-is: the new Starlark `assemble_venv` symlinks whole site-packages trees rather than iterating individual files. A port would require iterating wheel contents (impractical in Starlark) or filtering at the wheel-unpack layer.

## Adaptations made to remaining patches

Several patches needed adjustment to fit current `main`:

- **`fceb433`** (`9c1e4de`, "preserve wheel metadata and expose dist_info") — applied as additions-only, because parts of the patch depend on the `lib_mode` flag, `libs_are_libs`/`libs_are_whls` config_settings, and `whl_requirements` rule that [#951](https://github.com/aspect-build/rules_py/pull/951) intentionally removed as dead code; the upstream `:whl` alias was further removed by [#970](https://github.com/aspect-build/rules_py/pull/970).
  - Kept: `:pkg` alias, populated `all_requirements` / `all_whl_requirements_by_package` / `requirement(name)` in the generated `requirements.bzl`, `_merge_build_deps` helper, `normalize_name(project_name)`, `overridden_packages` tracking, install_cfg merging (`existing_install_cfg`), `normalize_version` repo-name char filtering, `_compatible_python_tags` abi3 fan-out, default `build_dependencies` adding `setuptools` and `wheel`.
  - Dropped: re-introduction of the `whl_requirements` rule and the `libs_are_libs`/`libs_are_whls` `select(...)` in `whl_install/repository.bzl`.
  - **Note:** the generated `requirements.bzl` still emits `@@<hub>//<pkg>:whl` labels in `all_whl_requirements_by_package`, but those `:whl` targets are not created — anyone evaluating `all_whl_requirements` will get an unknown-target error. Cleanup TBD if/when downstreams hit this.
  - **Note:** the patch changed `bdist_table.get(whl["url"])` → `bdist_table.get(whl["hash"])`, but `bdist_table` is keyed by `whl["url"]` in `uv/private/extension/lockfile.bzl`. Kept `whl["url"]` here.

- **`f0f1bbe`** (`5d81044`, "wrap sdist compilers to strip unsupported debug flags") — adapted for the JDK-discovery patch (`63f444e`) being dropped during the rebase onto [#1004](https://github.com/aspect-build/rules_py/pull/1004). The patch was originally authored on top of `63f444e`'s `_is_valid_java_home` / `_discover_java_home` helpers, and the merge conflict reflected that (those helpers appeared as added-context in the patch's diff). Kept only the compiler-wrapper additions (`_DEBUG_FLAG`, `_COMPILER_WRAPPER`, `_make_compiler_wrapper`, `_override_tool`, `_compiler_env`, and the `build_env = _compiler_env(tmp_root)` rebinding); dropped the JDK helpers and the `JAVA_HOME` fallback block (handled now by `uv.override_package(toolchains = ...)` per #1004).

- **`e6c3bc2`** (`ecd1eb6`, "reset Python flags on data edges") — adapted for [#976](https://github.com/aspect-build/rules_py/pull/976) (`venv` → `dep_group` rename):
  - `transitions.bzl`: `VENV_FLAG` → `DEP_GROUP_FLAG`; reset default changed from upstream's `"bazel-pypi-lock"` to `""` (the value of `build_setting_default` on `//uv/private/constraints/dep_group:dep_group`).
  - `py/tests/reset-data-edges/BUILD.bazel`: `venv = "reset-data-edges"` → `dep_group = "reset-data-edges"`.
  - `py/tests/reset-data-edges/probe.bzl`: `_venv` attr → `_dep_group` attr, label pointed at the new flag.
  - `py/tests/reset-data-edges/{main,test_main}.py`: expected probe content updated from `venv=bazel-pypi-lock` to `dep_group=` (the empty default).

- **`8d8e7e5`** (`8d8371f`, "require an explicit venv for target compatibility") — error message reworded for the `venv` → `dep_group` rename. The CLI flag is now `--@aspect_rules_py//uv/private/constraints/dep_group:dep_group=<name>`, and the target attribute is `dep_group = ...`.

## Re-running the cherry-pick

```bash
git remote add zbarsky-openai https://github.com/zbarsky-openai/rules_py.git
git fetch zbarsky-openai openai/v1.11.1-monorepo-patch-stack-20260413
git cherry-pick v1.11.1..zbarsky-openai/openai/v1.11.1-monorepo-patch-stack-20260413
```

Expect conflicts on commits modifying `py/private/py_binary.bzl`, `py/private/run.tmpl.sh`, `py/defs.bzl`, `py/tools/py/src/venv.rs`, `py/tools/unpack_bin/src/main.rs`, `uv/private/defs.bzl`, and `uv/private/{extension/defs.bzl,uv_hub/repository.bzl,whl_install/repository.bzl}` — see the "Adaptations" and "Skipped" sections above.
