# Migrating from `aspect_rules_py` 1.x to 2.0.0

v2.0.0 consolidates the `py_binary` / `py_venv_binary` code paths, graduates
the `/unstable/` load paths, drops runtime venv assembly in favor of an
analysis-time model, and removes some Rust tooling whose job is now done in
Starlark.

**Every breaking change surfaces with a clear error at analysis time** —
there is no silent-fail path. Running `bazel test //...` after the version
bump will name every callsite that needs updating.

This guide walks through each breaking change with concrete before/after
examples.

## Quick reference

| What you had in 1.x                               | What to do in 2.0.0                                                                               |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| `py_venv_binary(name = ...)`                      | `py_binary(name = ..., expose_venv = True, isolated = False)` (or plain `py_binary` for the common case) |
| `py_venv_test(name = ...)`                        | `py_test(name = ..., expose_venv = True, isolated = False)` (or plain `py_test`)                 |
| `load("@aspect_rules_py//py/unstable:defs.bzl", ...)` | `load("@aspect_rules_py//py:defs.bzl", ...)`                                                      |
| `load("@aspect_rules_py//uv/unstable:defs.bzl", ...)` | `load("@aspect_rules_py//uv:defs.bzl", ...)`                                                      |
| `use_extension("@aspect_rules_py//py/unstable:extension.bzl", ...)` | `use_extension("@aspect_rules_py//py:extensions.bzl", ...)`                    |
| `use_extension("@aspect_rules_py//uv/unstable:extension.bzl", ...)` | `use_extension("@aspect_rules_py//uv:extensions.bzl", ...)`                    |
| `bazel run :<name>.venv` (auto-emitted sibling)   | Add `expose_venv = True` on the binary + declare `py_venv_link` for the workspace-materialise affordance |
| `py_venv_link(name = ..., srcs = ..., deps = ...)` | `py_venv_link(name = ..., venv = ":<label>")` — takes an existing `py_venv` target               |
| Registered `VENV_TOOLCHAIN` / `VENV_EXEC_TOOLCHAIN` / `SHIM_TOOLCHAIN` overrides | Delete the registrations — these toolchain types no longer exist      |

## 1. `py_venv_binary` / `py_venv_test` were removed

Calling either macro now fails at analysis with a migration message. The
replacement is plain `py_binary` / `py_test`. For most users that means
dropping the macro name and keeping everything else the same —
analysis-time venv assembly is the default.

### Common case (most callers)

```starlark
# Before (1.x)
load("@aspect_rules_py//py/unstable:defs.bzl", "py_venv_binary")

py_venv_binary(
    name = "my_tool",
    srcs = ["my_tool.py"],
    main = "my_tool.py",
    deps = ["@pypi//requests"],
)
```

```starlark
# After (2.0.0) — plain py_binary
load("@aspect_rules_py//py:defs.bzl", "py_binary")

py_binary(
    name = "my_tool",
    srcs = ["my_tool.py"],
    main = "my_tool.py",
    deps = ["@pypi//requests"],
)
```

That's it. The binary still assembles a real venv on disk; the difference
is that assembly now happens at analysis time (free at runtime) and the
venv lives as an internal output of the target, not as a separately-
addressable graph node.

### When you need the old "sibling venv" shape

If your code relied on the py_venv_binary split — a separate `py_venv`
target that other binaries could share via `external_venv`, or that you
ran directly to drop into an interpreter — use `expose_venv = True`:

```starlark
py_binary(
    name = "my_tool",
    srcs = ["my_tool.py"],
    main = "my_tool.py",
    deps = ["@pypi//requests"],

    expose_venv = True,   # emits a sibling :my_tool.venv py_venv
    isolated = False,     # keep PYTHONPATH / script-dir / user-site semantics
)
```

`expose_venv = True` produces a first-class `:my_tool.venv` sibling that
is:
- **Consumable**: another `py_binary(external_venv = "//:my_tool.venv")` can point at it
- **Runnable**: `bazel run :my_tool.venv` drops into the hermetic interpreter

`isolated = False` drops Python's `-I` flag so the launcher honors
`PYTHONPATH`, auto-adds the script's directory to `sys.path`, and respects
user-site — matching the legacy `py_venv_binary` launcher shape.

### The same story for `py_venv_test`

```starlark
# Before (1.x)
load("@aspect_rules_py//py/unstable:defs.bzl", "py_venv_test")

py_venv_test(
    name = "my_test",
    srcs = ["my_test.py"],
    main = "my_test.py",
    deps = ["@pypi//pytest"],
)
```

```starlark
# After (2.0.0)
load("@aspect_rules_py//py:defs.bzl", "py_test")

py_test(
    name = "my_test",
    srcs = ["my_test.py"],
    main = "my_test.py",
    deps = ["@pypi//pytest"],
)
```

## 2. `/unstable/` load paths were removed

The four `/unstable/` facades — `//py/unstable:defs.bzl`,
`//py/unstable:extension.bzl`, `//uv/unstable:defs.bzl`,
`//uv/unstable:extension.bzl` — all `fail()` at load time with a message
naming the stable replacement.

### `BUILD.bazel` load statements

```starlark
# Before (1.x)
load("@aspect_rules_py//py/unstable:defs.bzl", "py_venv")
load("@aspect_rules_py//uv/unstable:defs.bzl", "gazelle_python_manifest", "py_console_script_binary")

# After (2.0.0)
load("@aspect_rules_py//py:defs.bzl", "py_venv")
load("@aspect_rules_py//uv:defs.bzl", "gazelle_python_manifest", "py_console_script_binary")
```

### `MODULE.bazel` extensions

```starlark
# Before (1.x)
interpreters = use_extension("@aspect_rules_py//py/unstable:extension.bzl", "python_interpreters")
uv = use_extension("@aspect_rules_py//uv/unstable:extension.bzl", "uv")

# After (2.0.0)
interpreters = use_extension("@aspect_rules_py//py:extensions.bzl", "python_interpreters")
uv = use_extension("@aspect_rules_py//uv:extensions.bzl", "uv")
```

The extensions and macros themselves are unchanged — only the load paths.
`@aspect_rules_py//py:extensions.bzl` also exposes `py_tools` (unchanged
from 1.x; it always lived there).

### What moved, summarised

| 1.x load path                                     | 2.0.0 load path                                   | Symbols                                                                       |
| ------------------------------------------------- | ------------------------------------------------- | ----------------------------------------------------------------------------- |
| `//py/unstable:defs.bzl`                          | `//py:defs.bzl`                                   | `py_venv`, `py_venv_link` (plus `py_venv_binary`/`py_venv_test` as fail-stubs) |
| `//py/unstable:extension.bzl`                     | `//py:extensions.bzl`                             | `python_interpreters`                                                         |
| `//uv/unstable:defs.bzl`                          | `//uv:defs.bzl`                                   | `gazelle_python_manifest`, `py_entrypoint_binary`, `py_console_script_binary` |
| `//uv/unstable:extension.bzl`                     | `//uv:extensions.bzl`                             | `uv`                                                                          |

## 3. Auto-emitted `:<name>.venv` sibling is gone

In 1.x, every `py_binary` / `py_test` macro call silently emitted a
`:<name>.venv` sibling — a `py_venv_link` target whose `bazel run`
materialised a workspace-local symlink for IDE integration. In 2.0.0 that
auto-emit is removed.

### What breaks

Any command or documentation that relied on the auto-emitted sibling
existing:

```sh
# 1.x — worked for every py_binary in the repo
bazel run //some/pkg:my_app.venv
```

In 2.0.0 this returns "no such target" unless you explicitly opt in.

### How to opt in

Set `expose_venv = True` on the binary — this emits a first-class sibling
`py_venv`. That target is runnable on its own (drops into the
interpreter), so most IDE workflows don't need anything else:

```starlark
py_binary(
    name = "my_app",
    srcs = ["main.py"],
    deps = ["@pypi//fastapi"],
    expose_venv = True,
)
```

```sh
bazel run //some/pkg:my_app.venv   # drops into the hermetic interpreter
```

If you specifically need the workspace-materialise-a-symlink behavior
(for an IDE that wants a stable path to the venv), declare `py_venv_link`
explicitly:

```starlark
load("@aspect_rules_py//py:defs.bzl", "py_binary", "py_venv_link")

py_binary(
    name = "my_app",
    srcs = ["main.py"],
    deps = ["@pypi//fastapi"],
    expose_venv = True,            # emits :my_app.venv py_venv
)

py_venv_link(
    name = "my_app_ide",
    venv = ":my_app.venv",          # link-materialise the sibling
)
```

```sh
bazel run //some/pkg:my_app_ide    # creates a workspace-local .venv symlink
```

### Why we made the change

In large monorepos the auto-emit doubled the target count (`bazel
query :*` output, gazelle walks, IDE graph-scrapers) for every
`py_binary` — thousands of extra nodes nobody asked for. Making IDE
integration opt-in trades a bit of boilerplate for a cleaner graph. It
also frees the `:<name>.venv` label to mean "the actual venv" instead
of "a link-script target that happens to be named like a venv," which
matches user intuition.

## 4. `py_venv_link` signature changed

The `py_venv_link` macro no longer builds its own venv. It now takes a
pre-existing `py_venv` label via the `venv` attribute.

```starlark
# Before (1.x) — py_venv_link built its own venv
py_venv_link(
    name = "my_venv",
    srcs = ["main.py"],
    deps = ["@pypi//fastapi"],
    imports = ["."],
)
```

```starlark
# After (2.0.0) — py_venv_link consumes an existing py_venv
py_venv(
    name = "my_venv_target",
    deps = ["@pypi//fastapi"],
    imports = ["."],
)

py_venv_link(
    name = "my_venv",
    venv = ":my_venv_target",
)
```

This separation means IDE workflows typically point at an existing
`py_binary(expose_venv = True, ...)`'s auto-emitted `:<name>.venv`
sibling rather than declaring a separate `py_venv` just for the link.

## 5. Rust `VENV_TOOLCHAIN` / `VENV_EXEC_TOOLCHAIN` / `SHIM_TOOLCHAIN` types were removed

These toolchain types are gone — their work (runtime venv staging,
interpreter-indirection shim) is now done in Starlark at analysis time.

If you registered overrides for any of these toolchain types, delete the
registrations. Leaving them in place produces toolchain-resolution errors
that are not self-explanatory.

```starlark
# Before (1.x) — remove lines like these from MODULE.bazel / WORKSPACE
register_toolchains("//my_custom:venv_toolchain")
register_toolchains("//my_custom:venv_exec_toolchain")
register_toolchains("//my_custom:shim_toolchain")
```

```starlark
# After (2.0.0) — just delete the lines; there's no replacement needed
```

Only `unpack` remains of the Rust tooling — it's still registered
automatically via the `py_tools` extension and requires no user
configuration.

## 6. Venv internal layout: two-hop site-packages symlinks

This one doesn't require a migration for most users but may affect
tooling that walks the venv directory tree.

**Before**: `<venv>/lib/python<ver>/site-packages/<top_level>` was a
single symlink pointing directly at the wheel's materialised tree.

**After**: `<venv>/lib/python<ver>/site-packages/<top_level>` is a
relative symlink that routes through an intermediate
`<venv>/_wheels/<i>/` directory alias, which itself symlinks to the
wheel's materialised tree.

Python-level consumers (`site.py`, `importlib`, every normal user) see
no difference — same `import`, same `sys.path`, same behavior.
Filesystem-walking tools may need to dereference the intermediate hop:

- **Custom `tar_rule` invocations** that treat venv symlinks specially
- **PEX-style packagers** that copy `site-packages/` contents
- **Docker build scripts** that walk the venv tree looking for wheels

If you have tooling in this category, test against a 2.0.0 venv and
follow the extra hop. The relative-link depth is identical in
`bazel-bin/`, runfiles, and inside an OCI image, so the new shape is
strictly more portable than the old one.

## Troubleshooting

### "target 'foo.venv' not declared in package"

Something in your repo (a shell script, CI config, IDE launch.json, etc.)
is trying to `bazel run` or `bazel build` a `:<name>.venv` target that
used to exist automatically. Fix by adding `expose_venv = True` to the
`py_binary` target — see section 3 above.

### "Error in fail: rules_py v2.0.0: @aspect_rules_py//py/unstable:..."

A `load()` or `use_extension()` still points at a `/unstable/` path. Fix
by switching to the stable path — see section 2 above.

### "Error in fail: py_venv_binary(name = ...) was removed in rules_py v2.0.0"

A macro call still invokes `py_venv_binary` or `py_venv_test`. Fix by
switching to `py_binary` / `py_test` — see section 1 above.

### "no such attribute 'external_venv' in 'py_binary' rule"

This error means something other than `aspect_rules_py` 2.0.0's
`py_binary` is being invoked — most commonly `rules_python`'s
`py_binary`, if your load statement drifted. Confirm your load points
at `@aspect_rules_py//py:defs.bzl`, not `@rules_python//python:defs.bzl`.

### "py_binary: `external_venv = ...` doesn't cover this binary's dep closure"

This is an analysis-time check firing — the binary declares wheels or
first-party imports that the shared venv doesn't carry. Either add the
missing deps to the venv, or drop `external_venv` and let the binary
build its own internal venv.

## What didn't change

For the skim-reader, these things are unchanged and don't need migration:

- **The string `venv = "..."` attribute** (uv's pip-extension venv-selection attr)
  is unchanged. The new `external_venv = :label` is a separately-typed
  attribute that coexists with it.
- **`py_binary` callers** who don't opt into `external_venv`, `expose_venv`,
  or `isolated = False` see no API changes — only a launcher-startup
  performance improvement (milliseconds instead of seconds on large
  monorepos).
- **The default on-disk venv basename** stays `.<name>.venv/`. IDE
  auto-detection paths that pointed there continue to work.
- **`py_tools`** lived at `@aspect_rules_py//py:extensions.bzl` in 1.x and
  still does. No change for callers who registered the py-tools toolchain.
- **`rules_python`-style API** — `py_binary`, `py_library`, `py_test`,
  `py_pytest_main`, `py_image_layer` — all unchanged in shape.
