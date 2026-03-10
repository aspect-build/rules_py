# Getting Started — Proposed Outline

This document outlines the structure for a new README.md / getting-started
experience that positions `aspect_rules_py` as a standalone Python ruleset
rather than a "layer on top of rules_python".

## Problems with the current README

- Opens by defining itself relative to rules_python ("a layer on top of")
- The layer table still lists rules_python as the interpreter provider
- The "Differences" section is a bug list against rules_python circa 2023
- The starlarkification note is stale and combative
- No mention of interpreter provisioning, uv, dependency groups, venvs
- No actual getting-started tutorial — just "look at the releases page"
- Migration guidance is a stub

## Proposed README.md structure

### 1. Headline + one-paragraph pitch

Position: `aspect_rules_py` is a complete Python ruleset for Bazel. It
provisions interpreters, manages PyPI dependencies via uv lockfiles, and
provides hermetic `py_binary`/`py_test`/`py_library` rules — all without
requiring `rules_python` for anything beyond base provider interop.

Key selling points (3-4 bullets, not a bug list):
- Hermetic interpreters from python-build-standalone, no manifests to maintain
- PyPI dependencies via uv lockfiles — fast, cross-platform, correct sdist builds
- Virtualenv-based runtime — `site-packages` layout, IDE-friendly, no sys.path hacks
- Drop-in migration from rules_python for existing projects

### 2. Quick start (zero to building)

Concrete, copy-paste tutorial. Three phases:

#### Phase 1: Module setup + interpreter

```starlark
# MODULE.bazel
bazel_dep(name = "aspect_rules_py", version = "...")

interpreters = use_extension("@aspect_rules_py//py/unstable:extension.bzl", "python_interpreters")
interpreters.toolchain(python_version = "3.12", is_default = True)
use_repo(interpreters, "python_interpreters")
register_toolchains("@python_interpreters//:all")
```

```
# .bazelrc
common --@aspect_rules_py//py:python_version=3.12
```

Explanation: what this does, why .bazelrc is good practice.

#### Phase 2: Add PyPI dependencies

```toml
# pyproject.toml
[project]
name = "myproject"
version = "0.0.0"
requires-python = ">=3.12"
dependencies = ["flask", "requests"]
```

```shell
uv lock
```

```starlark
# MODULE.bazel (continued)
uv = use_extension("@aspect_rules_py//uv/unstable:extension.bzl", "uv")
uv.declare_hub(hub_name = "pypi")
uv.project(
    hub_name = "pypi",
    pyproject = "//:pyproject.toml",
    lock = "//:uv.lock",
)
use_repo(uv, "pypi")
```

```
# .bazelrc (continued)
common --@pypi//venv=myproject
```

#### Phase 3: Write a target

```starlark
# BUILD.bazel
load("@aspect_rules_py//py:defs.bzl", "py_binary")

py_binary(
    name = "app",
    srcs = ["app.py"],
    deps = ["@pypi//flask", "@pypi//requests"],
)
```

```shell
bazel run //:app
```

### 3. What's in the box

Replace the old "layer" table with a capabilities table that reflects the
current state:

| Capability | aspect_rules_py | How |
|---|---|---|
| Interpreter provisioning | `//py/unstable:extension.bzl` | PBS releases, automatic version discovery |
| PyPI dependency management | `//uv/unstable:extension.bzl` | uv lockfiles, cross-platform, sdist builds |
| Rules (`py_binary`, etc.) | `//py:defs.bzl` | Virtualenv-based, hermetic, IDE-friendly |
| Venv rules (`py_venv_binary`, etc.) | `//py/unstable:defs.bzl` | Explicit venv control, venv transitions |
| Gazelle integration | aspect-gazelle | `gazelle_python_manifest` for import resolution |

### 4. Why aspect_rules_py (brief, non-combative)

Short section explaining the design philosophy. Not a bug list against
rules_python, but positive statements about what this ruleset does:

- Standard `site-packages` layout (virtualenv, not sys.path manipulation)
- Isolated mode by default (no sandbox escapes)
- Lazy dependency fetching (no repository-time downloads)
- Cross-platform by construction (platform-aware wheel selection at build time)
- Sdist builds using hermetic toolchains

One sentence acknowledging interop: "aspect_rules_py reuses rules_python's
base providers and toolchain types for interoperability."

### 5. Next steps / further reading

Links to the detailed docs, organized as a learning path:

- [Interpreter provisioning](docs/interpreter.md) — configuring releases,
  version selection, freethreaded builds
- [uv dependency management](docs/uv.md) — hubs, venvs, crossbuilds,
  overrides, gazelle
- [uv patching](docs/uv-patching.md) — patching wheels
- [Migrating from rules_python](docs/migrating.md) — drop-in replacement guide
- [Virtual dependencies](docs/virtual_deps.md)
- [Dev dependency patterns](examples/dev_deps/README.md) — conditional deps
  with dependency groups

### 6. Operational details (footer)

- Starter template repo link
- Gazelle `map_kind` directives (keep, but move out of the main narrative)
- Public API link to Bazel registry
- Telemetry notice
- Paid support link

## What to do with docs/migrating.md

The current migration doc is a stub. It should be expanded as a companion to
the new README, covering:

- Load statement changes (`@rules_python` → `@aspect_rules_py`)
- Interpreter swap (`python.toolchain()` → `interpreters.toolchain()`)
- Dependency swap (`pip.parse()` → `uv.project()` + lockfile generation)
- .bazelrc changes (python_version flag, venv flag)
- Gazelle map_kind directives
- Known behavioral differences (site-packages layout, isolated mode)

## Open questions

1. Should the README itself be the tutorial, or should README be a landing page
   that links to `docs/getting-started.md` for the full walkthrough?

2. The training course link and YouTube video — keep, move to a "Learn more"
   section, or drop? The video may be stale if it predates interpreter
   provisioning and uv.

3. The starter template repo (bazel-starters/py) — is it up to date with the
   new interpreter provisioning and uv workflow? If not, it should be updated
   before we link to it prominently.
