# Design: Reorganize `uv_project` snapshots into their own package

## Summary
Move the repository-rule output snapshots that represent `uv_project` generated
BUILD files from `uv/private/uv_hub/snapshots/` to `uv/private/uv_project/snapshots/`,
and add the missing `private/dep_group` snapshot. Each Bazel package will then
own the snapshots that exercise its own rules.

## Motivation
`uv/private/uv_project/BUILD.bazel` already contains an empty `write_source_files`
call, suggesting that snapshots for the `uv_project` repository rule were always
intended to live there. Today those snapshots are generated inside the `uv_hub`
package, which conflates two responsibilities:

- `uv_hub` snapshots test the public hub surface (`@pypi//...`).
- `uv_project` snapshots test the per-project repository surface
  (`@project__...//...`).

Separating them makes it easier to see which package a snapshot diff belongs to
and follows the existing convention that each rules package owns its own
snapshot tests.

## Changes

### 1. Create `uv/private/uv_project/snapshots/`
A data-only directory (no `BUILD.bazel` inside) so that `.gitattributes` marks
the whole tree as `linguist-generated`.

### 2. Move existing `uv_project` snapshots from `uv_hub`
| From | To |
|---|---|
| `uv/private/uv_hub/snapshots/project.BUILD.bazel` | `uv/private/uv_project/snapshots/project.BUILD.bazel` |
| `uv/private/uv_hub/snapshots/project.private.sccs.BUILD.bazel` | `uv/private/uv_project/snapshots/project.private.sccs.BUILD.bazel` |
| `uv/private/uv_hub/snapshots/project.private.markers.BUILD.bazel` | `uv/private/uv_project/snapshots/project.private.markers.BUILD.bazel` |

### 3. Add missing snapshot
| Snapshot | Source generated file |
|---|---|
| `uv/private/uv_project/snapshots/project.private.dep_group.BUILD.bazel` | `@project__aspect_rules_py//private/dep_group:BUILD.bazel` |

This snapshot pins the shape of the internal `config_setting` surface created
for each dependency-group configuration.

### 4. Update `uv/private/uv_project/BUILD.bazel`
Replace the empty `write_source_files` with a populated one:

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

### 5. Update `uv/private/uv_hub/BUILD.bazel`
Remove the four entries moved to `uv_project`, and update the comment so it no
longer claims to cover `uv_project` snapshots.

## Verification
- `bazel test //uv/private/uv_project:snapshots` passes.
- `bazel test //uv/private/uv_hub:snapshots` passes.
- If the lockfile has changed intentionally, running
  `bazel run //uv/private/uv_project:snapshots` updates the new location.

## Out of scope
- No changes to the repository-rule implementation.
- No new e2e projects or additional dependency-group configurations.
- No renaming of the snapshot files; the `project.` prefix is retained to match
  the `@project__aspect_rules_py` repository name.
