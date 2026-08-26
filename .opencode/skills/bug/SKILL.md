---
name: bug
description: Use when fixing a bug or regression in aspect_rules_py. Reproduces the failure with a new e2e case under e2e/cases/, then implements the fix in py/ or uv/, then verifies. Leaves all changes uncommitted for manual review. Trigger on words like "bug", "regression", "broken", "fix this", "reproduce", or when given an issue number.
---

# Bug-fix workflow for aspect_rules_py

This skill reproduces a reported bug as a regression test under `e2e/cases/`,
implements the fix in the ruleset source, and verifies the fix passes. Every
change stays **uncommitted** for manual review.

## Hard rules

- **Never commit.** Stage nothing. Leave the tree dirty for the user to `git diff`.
- **The fix lives in `py/` or `uv/`.** The reproduction lives in `e2e/cases/`.
  These are separate Bazel workspaces linked by
  `local_path_override(module_name = "aspect_rules_py", path = "../..")` —
  edits to `py/` / `uv/` are picked up by the e2e workspace without a publish.
- **Name the case after the issue.** Convention is `<short-slug>-<issue-number>`
  (e.g. `venv-conflict-608`, `pytest-mock-530`). No issue number → drop suffix.
- **Reproduce before fixing, verify after fixing.** Two separate runs of the
  case. The first must fail (proving the repro), the second must pass.

## Step 1 — Reproduce: create the e2e case

Determine which of the three case patterns fits the bug. Read an existing
sibling case as a template before writing your own.

### Pattern A — plain build/run regression (no extra deps)

A `BUILD.bazel` target that the failure touches. Discovered automatically by
`bazel test //...`, so it must be a real `py_test` / `sh_test` / `build_test`.

Files:
```
e2e/cases/<case-slug>/
├── BUILD.bazel
└── <srcs>.py
```

Reference: `e2e/cases/venv-conflict-608/` (uses `build_test` to assert two
targets build together without an action conflict).

### Pattern B — regression needing third-party deps (uv hub)

Same as A, plus a `setup.MODULE.bazel` fragment that declares its own uv hub +
project, and a `uv.lock` + `pyproject.toml` when the deps aren't already
available in the shared cases workspace.

Files:
```
e2e/cases/<case-slug>/
├── BUILD.bazel
├── setup.MODULE.bazel      # declares hub + uv.project; reinstantiates use_extension
├── pyproject.toml          # only if new deps are needed
├── uv.lock                 # only if new deps are needed
└── <srcs>.py
```

The `setup.MODULE.bazel` must **re-instantiate** `use_extension` against
`@aspect_rules_py` (do NOT reuse the shared `uv` proxy from the root
`e2e/cases/MODULE.bazel`):

```starlark
uv = use_extension("@aspect_rules_py//uv:extensions.bzl", "uv")
uv.declare_hub(hub_name = "pypi_<case_slug>")
uv.project(
    hub_name = "pypi_<case_slug>",
    lock = "//<case-slug>:uv.lock",
    pyproject = "//<case-slug>:pyproject.toml",
)
use_repo(uv, "pypi_<case_slug>")
```

Reference: `e2e/cases/pytest-mock-530/setup.MODULE.bazel`.

**Register the fragment**: append one line to the root workspace module:
```starlark
# e2e/cases/MODULE.bazel — keep the alphabetical order of the include() list
include("//<case-slug>:setup.MODULE.bazel")
```

### Pattern C — assert a *build failure* (cannot be an sh_test under //...)

When the bug is that something should fail (or fail with a specific message),
it can't live under `//...`. Ship a `test.sh` that invokes bazel and asserts
on exit code / stderr. Targets in `BUILD.bazel` must be tagged `manual` so
`//...` skips them.

Files:
```
e2e/cases/<case-slug>/
├── BUILD.bazel
├── test.sh                 # self-locating: `cd "$(dirname "$0")/.."` to reach cases root
└── <fixtures>
```

The `test.sh` is discovered automatically by `e2e/cases/test.sh`'s
`*/test.sh` glob — no registration needed beyond dropping the file.

Reference: `e2e/cases/patch-failure/test.sh`. Honor `$BAZEL` (default
`bazel`) so CI can override the launcher.

## Step 2 — Run the case and confirm it FAILS

All commands run from the **`e2e/cases/`** workspace root.

```bash
# Pattern A / B: target is under //...
bazel test //<case-slug>:<target>

# Pattern C: run the script directly
bash <case-slug>/test.sh

# Whole workspace (slow, only as a final gate)
bazel test //...
```

If the case **passes** before the fix, the repro is wrong — the bug isn't
captured. Re-examine the failure mode before touching `py/` or `uv/`. Do not
move on to the fix with a green repro.

## Step 3 — Implement the fix

Edit the ruleset source under `py/` or `uv/`. The e2e workspace consumes it
via the `local_path_override`, so no republish is needed — the next bazel
invocation rebuilds the changed `.bzl` / providers.

When editing rule implementations, follow the codebase conventions:
- Providers and `make_wheel_record` live in `py/private/providers.bzl`.
- Venv assembly core is `py/private/py_venv/venv.bzl::assemble_venv`.
- Keep the `# HACK:` / `# TODO:` comment convention only for genuine
  workarounds (e.g. upstream Bazel bugs). No redundant inline comments.

## Step 4 — Run the case again and confirm it PASSES

Re-run the **exact same command** from Step 2. It must pass now. If it still
fails, the fix is incomplete — iterate on Step 3.

Optionally also run the broader suite around the touched component to catch
collateral regressions:
```bash
bazel test //py/tests/...   # unit/integration tests for the ruleset itself
```

## Step 5 — Hand off uncommitted

Stop. Do **not** `git add`, `git commit`, or `git stash`. Report to the user:
1. The case directory created and which pattern (A/B/C) was used.
2. The files changed in `py/` / `uv/` with `file:line` references.
3. The before (failing) and after (passing) command output summary.

Leave the decision to commit — including splitting the repro and the fix into
separate commits — to the user.

## Quick reference: case pattern chooser

| If the bug...                                               | Pattern | Needs setup.MODULE.bazel? | Discovery        |
|-------------------------------------------------------------|---------|---------------------------|------------------|
| ...is a runtime/build behavior of a target with no new deps | A       | No                        | `bazel test //...` |
| ...needs third-party wheels from a uv hub                   | B       | Yes (+ include() in root) | `bazel test //...` |
| ...is that a build *should* fail / emit a specific error    | C       | Maybe                     | `*/test.sh` glob  |
