# uv_project snapshots reorganization — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the `uv_project` generated BUILD snapshots from `uv/private/uv_hub/snapshots/` into `uv/private/uv_project/snapshots/`, add the missing `private/dep_group` snapshot, and update both `BUILD.bazel` files so each package owns its own snapshots.

**Architecture:** Use Bazel's `write_source_files` rule in `uv/private/uv_project/BUILD.bazel` to pin the four repository outputs produced by the `uv_project` repository rule. Remove the corresponding entries from `uv/private/uv_hub/BUILD.bazel` so the `uv_hub` package only snapshots hub-level outputs.

**Tech Stack:** Bazel, Starlark, `aspect_bazel_lib`'s `write_source_files`.

## Global Constraints
- Snapshot source files live in `snapshots/` (data-only directory, no `BUILD.bazel` inside).
- `.gitattributes` already marks `**/snapshots/**` as `linguist-generated`.
- Snapshot file names keep the `project.` prefix to match the `@project__aspect_rules_py` repository.
- Update command after intentional lockfile changes: `bazel run //uv/private/uv_project:snapshots`.

---

## File Structure

| File | Responsibility |
|---|---|
| `uv/private/uv_project/snapshots/` (new dir) | Data-only directory holding the four `uv_project` snapshot files. |
| `uv/private/uv_project/BUILD.bazel` | Defines the `write_source_files` target named `snapshots` for the `uv_project` package. |
| `uv/private/uv_hub/BUILD.bazel` | Existing `write_source_files` target; remove the four `uv_project`-related entries. |

---

### Task 1: Create the new snapshots directory and move existing `uv_project` snapshots

**Files:**
- Create: `uv/private/uv_project/snapshots/project.BUILD.bazel`
- Create: `uv/private/uv_project/snapshots/project.private.sccs.BUILD.bazel`
- Create: `uv/private/uv_project/snapshots/project.private.markers.BUILD.bazel`
- Delete: `uv/private/uv_hub/snapshots/project.BUILD.bazel`
- Delete: `uv/private/uv_hub/snapshots/project.private.sccs.BUILD.bazel`
- Delete: `uv/private/uv_hub/snapshots/project.private.markers.BUILD.bazel`

**Interfaces:**
- Consumes: Existing snapshot files generated from `@project__aspect_rules_py//...`.
- Produces: The same three snapshot files under the new `uv/private/uv_project/snapshots/` path.

- [ ] **Step 1: Create the new directory and move the files**

```bash
mkdir -p uv/private/uv_project/snapshots
mv uv/private/uv_hub/snapshots/project.BUILD.bazel uv/private/uv_project/snapshots/project.BUILD.bazel
mv uv/private/uv_hub/snapshots/project.private.sccs.BUILD.bazel uv/private/uv_project/snapshots/project.private.sccs.BUILD.bazel
mv uv/private/uv_hub/snapshots/project.private.markers.BUILD.bazel uv/private/uv_project/snapshots/project.private.markers.BUILD.bazel
```

- [ ] **Step 2: Verify the moves**

Run:
```bash
ls -1 uv/private/uv_project/snapshots/
ls -1 uv/private/uv_hub/snapshots/ | grep project || echo "no project snapshots remaining"
```

Expected:
```
project.BUILD.bazel
project.private.markers.BUILD.bazel
project.private.sccs.BUILD.bazel
no project snapshots remaining
```

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "refactor: move uv_project snapshots into uv_project package"
```

---

### Task 2: Populate `uv_project`'s `write_source_files` and add the missing `dep_group` snapshot

**Files:**
- Modify: `uv/private/uv_project/BUILD.bazel`
- Create: `uv/private/uv_project/snapshots/project.private.dep_group.BUILD.bazel`

**Interfaces:**
- Consumes: `@project__aspect_rules_py//:BUILD.bazel`, `@project__aspect_rules_py//private/sccs:BUILD.bazel`, `@project__aspect_rules_py//private/markers:BUILD.bazel`, `@project__aspect_rules_py//private/dep_group:BUILD.bazel`.
- Produces: A `write_source_files` target named `snapshots` that maps the four generated files into `uv/private/uv_project/snapshots/`.

- [ ] **Step 1: Read the current `uv_project/BUILD.bazel`**

Run:
```bash
cat uv/private/uv_project/BUILD.bazel
```

Confirm the file ends with an empty `write_source_files()` call.

- [ ] **Step 2: Replace the empty `write_source_files` block**

Edit `uv/private/uv_project/BUILD.bazel` so that the empty block becomes:

```starlark
write_source_files(
    name = "snapshots",
    files = {
        "snapshots/project.BUILD.bazel": "@project__aspect_rules_py//:BUILD.bazel",
        "snapshots/project.private.sccs.BUILD.bazel": "@project__aspect_rules_py//private/sccs:BUILD.bazel",
        "snapshots/project.private.markers.BUILD.bazel": "@project__aspect_rules_py//private/markers:BUILD.bazel",
        "snapshots/project.private.dep_group.BUILD.bazel": "@project__aspect_rules_py//private/dep_group:BUILD.bazel",
    },
)
```

- [ ] **Step 3: Generate the new `dep_group` snapshot**

Run:
```bash
bazel run //uv/private/uv_project:snapshots
```

Expected: The command succeeds and creates/updates all four snapshot files, including the new `snapshots/project.private.dep_group.BUILD.bazel`.

- [ ] **Step 4: Inspect the generated `dep_group` snapshot**

Run:
```bash
cat uv/private/uv_project/snapshots/project.private.dep_group.BUILD.bazel
```

Expected: It contains a `config_setting` named `aspect_rules_py` (or the relevant dependency-group name) that references the `dep_group` flag.

- [ ] **Step 5: Run the new snapshot test**

Run:
```bash
bazel test //uv/private/uv_project:snapshots
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: add uv_project snapshot target and dep_group snapshot"
```

---

### Task 3: Remove `uv_project` snapshots from `uv_hub`

**Files:**
- Modify: `uv/private/uv_hub/BUILD.bazel`

**Interfaces:**
- Consumes: The updated snapshot layout from Task 1 and Task 2.
- Produces: A `uv_hub` `write_source_files` block that no longer lists `project.*` snapshots.

- [ ] **Step 1: Read the current `uv_hub/BUILD.bazel`**

Run:
```bash
cat uv/private/uv_hub/BUILD.bazel
```

- [ ] **Step 2: Remove the four `uv_project` entries from the `files` dict**

Delete these entries from the `write_source_files` block:

```starlark
        # uv_project: package-name → SCC alias map. Pins how surface
        # packages are wired into the SCC-partitioned graph for one project.
        "snapshots/project.BUILD.bazel": "@project__aspect_rules_py//:BUILD.bazel",
        # uv_project: py_library SCC definitions with wheel installs and
        # cross-SCC deps. Pins the resolved dep graph at 78-package scale —
        # the most precise check on the partitioning algorithm.
        "snapshots/project.private.sccs.BUILD.bazel": "@project__aspect_rules_py//private/sccs:BUILD.bazel",
        # uv_project: decide_marker rules keyed by SHA1 of the marker
        # expression. Pins marker emission and the hashing scheme.
        "snapshots/project.private.markers.BUILD.bazel": "@project__aspect_rules_py//private/markers:BUILD.bazel",
```

- [ ] **Step 3: Update the intro comment**

Replace the comment block above `write_source_files` so it no longer says that multi-project shape is exercised by e2e. The new block should read:

```starlark
# Snapshots of generated repository files produced by rules_py's repo rules.
# Acts as a regression check on the public surface those rules emit so changes
# show up as a reviewable diff. Each entry below documents *what* shape the
# snapshot pins down.
#
# Source files live in snapshots/ which is a data-only directory (no BUILD
# inside) so the entire dir can be marked linguist-generated in .gitattributes.
#
# To update after an intentional change, run:
#   bazel run //uv/private/uv_hub:snapshots
```

- [ ] **Step 4: Run the `uv_hub` snapshot test**

Run:
```bash
bazel test //uv/private/uv_hub:snapshots
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: remove uv_project snapshots from uv_hub package"
```

---

### Task 4: Final verification

**Files:**
- None (read-only verification).

**Interfaces:**
- Consumes: The updated `BUILD.bazel` files and snapshot directories.
- Produces: Confirmation that both snapshot targets pass and no stale files remain.

- [ ] **Step 1: Run both snapshot test targets**

Run:
```bash
bazel test //uv/private/uv_project:snapshots //uv/private/uv_hub:snapshots
```

Expected: Both tests PASS.

- [ ] **Step 2: Check for stale references**

Run:
```bash
grep -R "project\.BUILD\.baz\|project\.private" uv/private/uv_hub/ || echo "no stale references"
```

Expected: "no stale references".

- [ ] **Step 3: Verify directory contents**

Run:
```bash
ls -1 uv/private/uv_project/snapshots/
ls -1 uv/private/uv_hub/snapshots/
```

Expected `uv_project/snapshots/`:
```
project.BUILD.bazel
project.private.dep_group.BUILD.bazel
project.private.markers.BUILD.bazel
project.private.sccs.BUILD.bazel
```

Expected `uv_hub/snapshots/` does **not** contain any `project.*` files.

- [ ] **Step 4: Commit (optional final checkpoint)**

If any fixes were needed, commit them:
```bash
git add -A && git commit -m "fixup: address verification findings"
```

---

## Self-Review

**Spec coverage:**
- Create `uv/private/uv_project/snapshots/` → Task 1.
- Move three existing snapshots → Task 1.
- Add `project.private.dep_group.BUILD.bazel` → Task 2.
- Update `uv/private/uv_project/BUILD.bazel` → Task 2.
- Update `uv/private/uv_hub/BUILD.bazel` → Task 3.
- Verification commands → Task 4.

**Placeholder scan:** No TBD/TODO/fill-in-details patterns remain.

**Type consistency:** Snapshot paths and repository labels match those used in the existing `uv_hub` block and in the design spec.
