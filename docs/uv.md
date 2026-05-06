# `aspect_rules_py//uv`

`aspect_rules_py` provides an alternative to the venerable `rules_python`
`pip.parse` implementation, which leverages the
[uv](https://github.com/astral-sh/uv) lockfiles instead of `requirements.txt` to
configure PyPi dependencies.

Our uv is a drop-in replacement for basic `pip.parse` usage, but provides a
number of additional features.

**Dependency groups** - Uv supports [PEP 735 dependency
groups](https://peps.python.org/pep-0735/): each project's
`[dependency-groups]` entries register as named groups in the hub, and
your build picks one by flipping `--@<hub>//dep_group=<name>` or setting
`dep_group="<name>"` on a `py_binary` / `py_test` target. Multiple
projects can share a hub, including with same-named groups (`prod`,
`dev`, …) — the hub publishes per-project qualified labels alongside the
unqualified ones to handle cross-project package overlap.

**Effortless Crossbuilds** - Uv delays building and installing packages until
the build is configured. This allows uv to build your requirements in crossbuild
configurations, such as going from a Darwin macbook to a Linux container image
using only the normal Bazel `platforms` machinery.

**Correct source builds** - Because uv performs package source builds as a
normal part of your build, it's able to use hermetic or even source built Python
toolchains in addition to Bazel-defined dependencies and C compilers. Future
support for sysroots is planned. Due to its phasing, `pip.parse` is stuck doing
all this non-hermetically.

**Editable requirements** - Uv provides an `uv.override_requirement()` tag which
allows locked requirements to be replaced with 1stparty Bazel `py_library`
targets. This lets you substitute in vendored code, use custom build actions to
produce library files, or just iterate on patches easily.

**Lightning fast configuration** - The only work uv has to do at repository time
is reading toml files. Downloads and builds all happen lazily.

**Platform independence** - No more need to separate `requirements_mac`,
`requirements_linux` and `requirements_windows` or your build exploding because
you `query`-ed a platform incompatible requirement. Uv can always configure all
of your requirements, and all hub labels are always available.

**Mirror friendly** - Relying on uv's locked dependency graph allows the
extension to only use the Bazel downloader, ensuring compatibility with private
or mirrored wheels.

**Automatic cycle support** - Requirement dependency cycles such as those in
Airflow are automatically detected and resolved. User intervention is no longer
required.

## Quickstart

The first step is to generate a `uv.lock` file. In contrast to a conventional
`requirements.txt`, the uv lockfile contains both the dependency graph between
requirements and detailed information about the wheels and sdists.

The `uv_bin.toolchain()` tag below registers a Bazel-managed `uv`, so you can
invoke it via `bazel run @uv -- …` without installing `uv` globally. From a
workspace that already has a `pyproject.toml`:

```shell
bazel run @uv -- lock
```

If you're migrating from `requirements.txt`, use uv's own import flow to
create a `pyproject.toml` and seed it:

```shell
bazel run @uv -- init --no-workspace
bazel run @uv -- add -r requirements_lock.txt
```

We can now use the lockfile to configure our build.

This configuration declares a dependency hub, registers a project (which
gives the hub its `[dependency-groups]` — here, a single `vendored_say`
group declared in the user's `pyproject.toml`), and shows how to use
`uv.override_package` to swap a locked requirement (`cowsay`) for a local
one.

```starlark
# MODULE.bazel
bazel_dep(name = "aspect_rules_py", version = "1.6.7") # Or later

uv_bin = use_extension("@aspect_rules_py//uv:extensions.bzl", "uv_bin")
uv_bin.toolchain(version = "0.11.6")
use_repo(uv_bin, "uv")

uv = use_extension("@aspect_rules_py//uv:extensions.bzl", "uv")
uv.declare_hub(
    hub_name = "pypi",      # Or whatever you wish
)
uv.project(
    hub_name = "pypi",      # Must be a declared hub
    pyproject = "//:pyproject.toml",
    lock = "//:uv.lock",
)

uv.override_package(
    lock = "//:uv.lock",
    name = "cowsay",
    # version = "",    Optional but may be required for disambiguation
    target = "//third_party/py/cowsay:cowsay",
)

# The hub aggregates every project bound to it; dependency groups are
# named per pyproject.toml's [dependency-groups] (or synthesized as the
# empty-keyed group `""` plus the project name if absent).
use_repo(uv, "pypi")

register_toolchains("@uv//:all")
```

Each `[dependency-groups]` entry in `pyproject.toml` registers as a named
group in the hub. The active group is selected at build time by the
`--@<hub>//dep_group=<name>` flag or by setting `dep_group="<name>"` on a
`py_binary` / `py_test` target. The flag defaults to `""`, which the
extension synthesizes for projects without explicit `[dependency-groups]`
— the simple case works zero-config. See
[Dependency groups](#dependency-groups) for the full semantics.

```
# .bazelrc — pick the explicit group as the workspace-wide default
common --@pypi//dep_group=vendored_say
```

Individual targets can request different dependency groups if multiple
dependency groups are configured.


```
# BUILD.bazel
load("@aspect_rules_py//py:defs.bzl", "py_binary")

py_binary(
   name = "say",
   srcs = ["__main__.py_"],
   deps = ["@pypi//cowsay"],
)

py_binary(
   name = "say_with_other_group",
   srcs = ["__main__.py_"],
   deps = ["@pypi//cowsay"],
   dep_group = "other_group",     # Override per-target
)
```

## Dependency groups

[PEP 735](https://peps.python.org/pep-0735/) defines `[dependency-groups]`
as named, opt-in subsets of a project's dependencies — declared in
`pyproject.toml`, independent of `[project].dependencies` and of extras.

```toml
[project]
name = "web"
dependencies = ["flask"]

[dependency-groups]
dev = ["pytest", "ruff"]
prod = ["gunicorn"]
```

Each entry registers as a name selectable via the `dep_group` flag or the
`dep_group="<name>"` attribute.

### Flag-value summary

The `dep_group` flag has a small, fixed grammar. Three shapes:

| Flag value          | Activates                                                          |
| ---                 | ---                                                                |
| `""` (empty)        | Synthesized empty-default group — fallback projects only           |
| `<group>`           | Every project's `<group>` group simultaneously (broad)             |
| `<name>`            | The synthesized `<name>` alias — fallback projects only            |
| `<name>/<group>`    | Just the named project's `<group>` group (narrow)                  |

`<name>` is always the PEP 503 normalized `[project].name`. The same token
appears in qualified hub labels (`@<hub>//project/<name>:<package>`) — the
`project/` prefix is preserved on labels because the package side comes
from PyPI, which the user doesn't control. Flag values, by contrast, sit
in a single user-controlled namespace (project names + group names);
collisions between the two are caught at hub construction time and
surfaced as a clear error.

`<group>` is any `[dependency-groups]` entry — or one of the synthesized
empty / `<name>` aliases when `[dependency-groups]` is absent.

The flag's `build_setting_default` is `""`, so projects without
`[dependency-groups]` resolve zero-config. Subsections below cover each
shape in detail.

### Default behavior when `dep_group` is unset

The flag defaults to `""`, matching the synthesis fallback's empty-keyed
group. Projects whose `pyproject.toml` lacks a `[dependency-groups]` table
need no `.bazelrc` configuration — they just work.

For projects that DO declare `[dependency-groups]`, the default flag value
matches none of the declared groups (PEP 735 forbids empty group names),
so the hub's package aliases fail with a `no_match_error` listing the
groups your project actually defines. Set the flag explicitly to one of
those.

```
common --@<hub>//dep_group=dev          # workspace-wide default
common:release --@<hub>//dep_group=prod # config-specific override
```

Per-target override: `dep_group="<name>"` on a `py_binary` / `py_test` /
`py_venv` rule sets the flag within that target's transition scope,
overriding whatever was inherited from the build flag. Useful when a
single binary needs a different dependency mix than the rest of the build.

Targets without an explicit `dep_group` attr inherit the active flag value
through the `python_transition`.

### Comparison with uv outside Bazel

If you're coming from a uv-CLI workflow, the Bazel model handles dep
groups differently in one key way: **`dep_group=<name>` selects exactly
one activation set, with no implicit overlay of `[project].dependencies`
on top.** The full mapping:

| uv CLI                            | Bazel `dep_group` equivalent                                                                  |
| ---                               | ---                                                                                           |
| `uv sync` (no flags)              | `dep_group=""` (synthesized for projects without explicit groups)                             |
| `uv sync --group dev`             | `dep_group="dev"`, where `dev` includes the project itself or `[project].dependencies`        |
| `uv sync --only-group dev`        | `dep_group="dev"` — this is the native Bazel semantics                                        |
| `uv sync --no-group dev`          | Don't activate `dev`; pick a different group via `dep_group=`                                 |

The Bazel form lines up with `--only-group`, not the default `--group`
(overlay) form. The `--group` overlay has no direct Bazel analogue —
users who want overlay behavior declare it explicitly in the toml; see
[Patterns](#patterns-for-overlay-behavior) below.

Why: each `dep_group` value has to map to exactly one `select()` arm at
analysis time, so it has to fully describe the desired install set —
there's nowhere to express "X plus Y" structurally without losing the
ability to enumerate at config time.

Other things that work the same way as uv CLI:

- `[dependency-groups]` declarations themselves are the standard PEP 735
  shape — uv reads the same toml in both contexts.
- `[project].dependencies` are still the project's runtime deps, the
  thing that gets shipped in a wheel, and the thing the synthesis
  fallback pulls into the auto-generated empty / `<name>` groups. Same
  rules as outside Bazel.
- `include-group` and the rest of PEP 735's group-composition syntax
  works identically.

### Patterns for overlay behavior

For projects with explicit `[dependency-groups]`, if you want
`[project].dependencies` available alongside the group's contents
(matching `uv sync --group <name>` semantics), wire it in yourself. Two
PEP 735 patterns work:

```toml
[project]
name = "web"
dependencies = ["flask"]

[dependency-groups]
# Self-reference. uv resolves `web` from the lockfile, where it's a
# virtual workspace member with deps = ["flask"]. Activating `dev`
# pulls in flask transitively + pytest.
dev = ["web", "pytest"]

# Or chain via PEP 735's `include-group`:
_base = ["web"]   # convention: leading underscore for "internal" groups
prod = [{ include-group = "_base" }, "gunicorn"]
```

### Synthesis fallback: empty and `<name>` aliases

When a project's `pyproject.toml` lacks a `[dependency-groups]` table
entirely, the extension synthesizes two equivalent group names mapping to
the project itself (which uv resolves to the project's
`[project].dependencies` transitively):

- **`""`** (empty) — matches the `dep_group` flag's
  `build_setting_default = ""`, so a single-project hub resolves with no
  `.bazelrc` configuration. PEP 735 forbids empty group names, so this
  can never collide with a user-declared group.
- **`<name>`** — same content, namespaced by the project's own name.
  Used for per-project isolation when multiple projects share a hub;
  see [Sharing a hub](#sharing-a-hub-across-multiple-projects).

`<name>` is the project's `[project].name` after PEP 503 normalization
(lowercase, hyphens → underscores) — the same token used in the
project-qualified hub label `@<hub>//project/<name>:<package>`.

Projects with explicit `[dependency-groups]` keep just their declared
groups — no implicit alias is added.

#### Collision with declared group names

The synthesized `<name>` alias and explicit `[dependency-groups]` entries
share one flat namespace at the flag-value layer. The extension fails
hub construction if a project's stamp matches a group name declared by
any *other* project in the same hub — both names are user-controlled and
locally adjustable, so the user just renames one. (A project naming a
group identically to itself is fine: synthesis only fires for projects
without `[dependency-groups]`, so the same project can never declare
both halves of the would-be collision.)

### Per-project narrow activation: `<name>/<group>`

Bare flag values like `dep_group="prod"` activate the `prod` group across
*every* project in the hub that declares one — usually fine, but in a
shared hub where two projects pin the same package at different versions
the unqualified `@<hub>//<package>` label can multi-match. The narrow
form `<name>/<group>` scopes activation to one project's group
without touching the deps list:

```python
# Both projects pin requests at different versions; the unqualified
# @hub//requests would multi-match. Narrow flag to scope to web's
# resolution without rewriting deps.
py_binary(
    name = "bin",
    srcs = ["main.py"],
    dep_group = "web/prod",
    deps = ["@<hub>//requests"],
)
```

This is the flag-value layer equivalent of the qualified hub label
`@<hub>//project/<name>:<package>`. Useful when a few targets in a
multi-project hub need to disambiguate without rewriting every dep label.

The narrow form is emitted for every explicitly-declared group in every
project. It's skipped for the synthesized empty and `<name>` aliases,
which the bare `""` and `<name>` flag values already handle for
synthesis-fallback projects.

### Authoring a library that's published *and* used in a Bazel build

A common shape: a Python library that's published to PyPI for downstream
consumers but also developed inside a Bazel workspace as a `uv.project()`.
The library declares `[project].dependencies` for its runtime deps (what
PyPI consumers receive) and `[dependency-groups]` for dev-time tooling.

The wrinkle: PEP 735 dep groups aren't shipped in wheels — published
consumers see only `[project].dependencies`, never the groups. So:

- For consumers (`pip install mylib` / `uv add mylib`): they get
  `flask`, `click`, etc. as expected. They never see `dev`/`prod`.
- For your own Bazel build: `dep_group="dev"` activates *only* what's
  listed under `[dependency-groups].dev`, with no automatic overlay of
  `[project].dependencies` (see the only-group note above). You need to
  wire the overlay yourself.

The `include-group` pattern keeps `[project].dependencies` referenced in
one place while letting both modes activate it:

```toml
[project]
name = "mylib"
version = "1.0.0"
dependencies = [
    "flask",          # what published consumers get
    "click",
]

[dependency-groups]
_runtime = ["mylib"]                                    # private "internal" group
prod = [{ include-group = "_runtime" }]
dev = [{ include-group = "_runtime" }, "pytest", "ruff"]
```

Now `dep_group="prod"` activates flask + click; `dep_group="dev"` activates
flask + click + pytest + ruff. The `[project].dependencies` list stays
the single source of truth, and the published wheel is unaffected.

If you don't actually need a `dev`/`prod` split inside the Bazel build
(e.g. your tests don't pull in extra runtime deps), simpler still: drop
`[dependency-groups]` entirely. The synthesis fallback gives you the
empty-keyed group and `<name>` for free, both activating the project's
transitive runtime deps. Use `uv sync --group dev` outside Bazel for
local-development tooling that doesn't need to be in the Bazel graph.

## Sharing a hub across multiple projects

Multiple `uv.project()` declarations can target the same hub. Each project
contributes its own packages and dependency-groups; the hub aggregates them.
Group names are namespaced internally by project, so two projects can each
define a `prod` group without colliding.

The hub publishes packages under two label shapes:

- **Unqualified** — `@<hub>//<package>`. Resolves at `select()` time based on
  the active `dep_group`. The hub deduplicates providers by `(group, version)`:
  when multiple projects provide the package in the same group at the *same
  version*, the alias collapses to a single canonical arm. Only a true version
  conflict — same group, different versions — surfaces Bazel's "multiple keys
  match", at which point reach for the qualified shape.
- **Project-qualified** — `@<hub>//project/<name>:<package>`. Always
  available; routes to the named project's resolution irrespective of
  overlap or version conflict. The `project/` prefix is reserved on the
  label side because the package side comes from PyPI, which the user
  doesn't control — without the prefix, picking a project name that
  matches a PyPI package would silently shadow it. Flag values, by
  contrast, sit in a single user-controlled namespace, so they don't
  need a reserved prefix.

```starlark
# MODULE.bazel
uv.declare_hub(hub_name = "pypi")
uv.project(
    hub_name = "pypi",
    pyproject = "//apps/web:pyproject.toml",
    lock = "//apps/web:uv.lock",
)
uv.project(
    hub_name = "pypi",
    pyproject = "//apps/worker:pyproject.toml",
    lock = "//apps/worker:uv.lock",
)
```

```starlark
# apps/web/BUILD.bazel
py_binary(
    name = "bin",
    srcs = ["main.py"],
    dep_group = "prod",
    deps = [
        "@pypi//flask",                       # unqualified — only `web` provides it
        "@pypi//project/web:requests",        # qualified — both projects ship `requests`
    ],
)

# apps/worker/BUILD.bazel
py_binary(
    name = "bin",
    srcs = ["main.py"],
    dep_group = "prod",
    deps = [
        "@pypi//celery",                      # unqualified — only `worker` provides it
        "@pypi//project/worker:requests",     # qualified
    ],
)
```

Setting `dep_group=prod` activates *both* projects' `prod` groups
simultaneously. When both projects pin a shared package at the same version
the unqualified label deduplicates to a single canonical resolution; only an
actual version conflict on the same group forces a qualified label.

> **Caveat:** dedup keys on `(group, version)` only. If two projects pin the
> same version but apply different `uv.override_package` overrides or
> `post_install_patches`, the canonical-arm choice is deterministic (lex-first
> by project name) but only one project's overrides apply — reach for the
> qualified label in that case.

In a multi-project hub where projects without explicit
`[dependency-groups]` all collapse into the synthesized empty-keyed
group, the `<name>` synthesis alias is the per-project escape hatch.
Setting `dep_group="<name>"` activates exactly one project's resolution
regardless of whether other projects pin the same package at different
versions:

```python
# Two projects bound to the same hub, both without [dependency-groups],
# both pinning `requests` at different versions. The unqualified
# `@<hub>//requests` would multi-match across the projects' synthesized
# empty-keyed groups; setting `dep_group="web"` selects only
# `web`'s resolution.
py_binary(
    name = "bin",
    srcs = ["main.py"],
    dep_group = "web",
    deps = ["@<hub>//requests"],
)
```

See [Synthesis fallback](#synthesis-fallback-empty-and-name-aliases)
for the full mechanics.

## The `uv` toolchain

`uv_bin.toolchain()` fetches the UV binary for the required platform(s) and
publishes `@uv`:

- `@uv//:uv` — host-platform alias for ad-hoc use (`bazel run @uv`,
  `genrule(tools=…)`, `sh_binary(data=…)`).
- `@uv//:all` — per-platform toolchains for `register_toolchains`.

Optional attributes:

- `name` — hub repo name; defaults to `"uv"` (i.e. `@uv`). Set to a distinct
  value to publish an additional hub (e.g. `@uv_legacy//:uv`) alongside the
  default.
- `version` — defaults to the latest version known to aspect_rules_py.
  Unknown versions are still fetchable but non-reproducible unless paired
  with `sha256s`.
- `urls` — mirror templates with `{version}`, `{platform}`, `{ext}`
  placeholders; tried in order. Defaults to the upstream GitHub release URL.
- `sha256s` — map of platform triple to SHA256. Overrides or supplies the
  hashes baked into aspect_rules_py. Entries are optional per-platform; a
  platform with an empty-string hash fetches without integrity verification
  and the download is marked non-reproducible (its bytes may vary across
  users).

## Relationship to interpreter provisioning

Unlike `rules_python`, there is no coupling between `uv.project()` and Python
interpreter provisioning. The uv extension only reads lockfiles and generates
build targets — it does not download or configure Python interpreters.

At build time, Bazel's normal toolchain resolution selects an interpreter. You
can provide one via `aspect_rules_py`'s own `python_interpreters` extension
(see [interpreter.md](interpreter.md)), via `rules_python`'s
`python.toolchain()`, or any other mechanism that registers a
`@bazel_tools//tools/python:toolchain_type` toolchain. As long as an
appropriate Python toolchain is registered for the target platform, uv targets
will build correctly regardless of how that toolchain was provisioned.

## Example: Doing crossbuilds

The uv machinery honors the `@platforms//cpu` and `@platforms//os` constraint
settings, and will attempt to provide installations of libraries matching the
active constraint set.

In order to cope with various libcs and libc compatibility ranges, uv also has
two internal config setting flags

```
--@aspect_rules_py//uv/private/constraints/platform:platform_libc=glibc
--@aspect_rules_py//uv/private/constraints/platform:platform_version=2.39
```

The `platform_libc` flag must be the name of a libc (eg. glibc, musl, libsystem,
...) and the `platform_version` flag must be the `major.minor` version of that
libc on the targeted system. This allows for users to specify that they're
crossbuilding from `linux-glibc@2.40` to `linux-musl@1.2` and such.

Crossbuilds can be accomplished simply by setting the `--platform` flag, or
using platform transitions.

```
load("@bazel_lib//lib:transitions.bzl", "platform_transition_filegroup")
load("@aspect_rules_py//py:defs.bzl", "py_binary", "py_image_layer")

platform(
    name = "arm64_linux",
    constraint_values = [
        "@platforms//os:linux",
        "@platforms//cpu:aarch64",
    ],
    # These flags must be reset to values appropriate for the target.
    # Their default values are appropriate to the host.
    flags = [
        "--@aspect_rules_py//uv/private/constraints/platform:platform_libc=glibc",
        "--@aspect_rules_py//uv/private/constraints/platform:platform_version=2.39",
    ],
)

py_binary(
    name = "app_bin",
    srcs = ["__main__.py"],
    main = "__main__.py",
    python_version = "3.12",
    dep_group = "psql",
    deps = [
        "@pypi//psycopg2_binary",
    ],
)

# OCI layers containing the binary
py_image_layer(
    name = "app_layers",
    binary = ":app_bin",
)

# The layers reconfigured according to the specified platform
platform_transition_filegroup(
    name = "arm64_layers",
    srcs = [":app_layers"],
    target_platform = ":arm64_linux",
)
```

## Example: Constraining library compatibility

By default uv hubs let you write `py_library` and other targets which are
compatible with _any_ dependency group providing all the needed
requirements.

But sometimes you want a library to be incompatible with a particular
dependency group — either because it depends on packages at versions
below what are available in that group, as part of an internal migration,
or for some other reason.

Each hub's `@<hub>//:defs.bzl` provides a pair of helper macros for
generating appropriate `target_compatible_with` logics. These helpers
return case dicts which may either be manipulated or `select()`ed on. They
take bare group names and fan out internally to the per-project
namespaced config_settings, so a single `compatible_with(["prod"])`
covers every project in the hub that defines a `prod` group.

```
load("@pypi//:defs.bzl", "compatible_with", "incompatible_with")

py_library(
  name = "requires_prod",
  srcs = ["foo.py"],
  deps = ["@pypi//cowsay"],
  # Only buildable when dep_group=prod is active.
  target_compatible_with = select(compatible_with(["prod"])),
)

py_library(
  name = "not_in_prod",
  srcs = ["foo.py"],
  deps = ["@pypi//cowsay"],
  # Buildable in any dep_group except prod.
  target_compatible_with = select(incompatible_with(["prod"])),
)
```

## A mental model

```
@pypi                                     # Your UV-built hub repository
@pypi//requests:requests                  # Unqualified library label
@pypi//project/web:requests               # Project-qualified label (when needed)
@pypi//jinja2-cli/entrypoints:jinja2-cli  # A requirement's declared entrypoint

```

The central hub wraps per-project repos generated from each `uv.project()`
declaration. Each top-level package alias resolves at `select()` time
based on the active `dep_group` flag, routing into the appropriate
project's lock resolution. Multiple projects can register groups of the
same name (e.g. both define `prod`); the per-project config_settings are
namespaced internally as `<project>__<group>` so `dep_group=prod`
activates every project's `prod` simultaneously.

When more than one project provides the same package at different
versions, the unqualified label `@<hub>//<package>` has multiple
`select()` arms matching at the active group. Bazel surfaces the
conflict and you reach for the project-qualified label
`@<hub>//project/<name>:<package>` — deterministic regardless of
overlap. The `project/` namespace is collision-free with Python
distribution names because `/` isn't a valid character in PEP 503 /
PEP 426 names.

Hub package targets are `target_compatible_with`-incompatible with
dependency groups that don't provide the package — wildcard builds skip
them cleanly, and explicit deps on missing packages produce a
`no_match_error` listing the dependency groups that do provide it.

Each requirement is backed by a `whl_install` rule which chooses among
prebuilt wheels listed in the lockfile to produce the equivalent of a
`py_library`. An sdist (if available) is built into a wheel when no
matching wheels are available; sdist builds use the configured Python and
Cc toolchains.

## Best practices

**Consolidate your hubs**. In `rules_python`, environments with multiple
dep sets needed multiple `pip.parse()` calls, each of which created a hub.
This produced transitive depset inconsistency (target uses deps from one
hub but depends on a library using deps from elsewhere).

A single hub aggregating multiple `uv.project()` declarations sidesteps
this. Reach for `dep_group` to switch between dependency sets at the
same hub label, and use project-qualified labels when two projects in
the hub provide the same package and you need to disambiguate.

**One hub per workspace, usually**. The hub name is configurable to
accommodate whatever your existing `pip.parse` may be called, but a
single hub aggregating every project keeps dependency management
internally consistent. Multiple hubs are supported but only really
warranted when dependency sets are intentionally siloed (e.g. tooling vs
runtime).

## Gazelle integration

If you use [Gazelle](https://github.com/bazelbuild/bazel-gazelle) with the
[aspect-gazelle](https://github.com/aspect-build/aspect-gazelle) Python
extension, you need a `gazelle_python.yaml` manifest that maps Python import
names to their PyPI package names. The `gazelle_python_manifest` rule generates
this file from your locked wheels.

```starlark
# BUILD.bazel (typically at the workspace root)
load("@aspect_rules_py//uv:defs.bzl", "gazelle_python_manifest")

gazelle_python_manifest(
    name = "gazelle_python_manifest",
    hub = "pypi",
    venvs = [""],          # synthesis-fallback empty-keyed group
)
```

**Parameters:**

- `hub` — The name of your uv hub (must match `uv.declare_hub(hub_name = ...)`).
- `venvs` — List of dependency group names whose wheels should be
  indexed. Module mappings from all listed groups are merged into a
  single manifest. (The attribute is named `venvs` for historical
  reasons; rename pending.)

This creates two targets:

- `:gazelle_python_manifest` — builds the manifest YAML
- `:gazelle_python_manifest.update` — copies the built manifest into your source tree

To generate or refresh the manifest:

```shell
bazel run //:gazelle_python_manifest.update
```

This writes `gazelle_python.yaml` next to the BUILD file. Commit it to your
repository so that Gazelle can resolve Python imports without rebuilding the
manifest on every invocation.

If you have multiple dependency groups with different dependency sets,
list them all to
produce a complete mapping:

```starlark
gazelle_python_manifest(
    name = "gazelle_python_manifest",
    hub = "pypi",
    venvs = ["web", "ml", "cli"],
)
```

## Differences and Gotchas

**Lock your build tools**. In order to perform sdist builds and support
libraries which are packaged only as sdists (which is more common than you'd
think) uv needs a Python build tool to use. Uv currently uses `setuptools` and
`build`, both of which must be installed in your lock solution. You may
encounter configuration errors if these tools would be required and are not
available.

The build tools declared via `uv.project(default_build_dependencies = ["build", "setuptools"])`
plus their transitive runtime closure are activated into the project's
`dep_to_scc` automatically — but only for projects WITHOUT explicit
`[dependency-groups]`. Projects with explicit groups own their build-tool
version pinning (often via `[tool.uv.conflicts]`) and are expected to
declare build tools inside the relevant group themselves; an automatic
extra activation could conflict with the user's declared pin.

**One global `dep_group` flag.** To implement the `dep_group` transition
on `py_binary` / `py_test` / `py_venv`, the flag has to be statically
known. There is one global `dep_group` flag, regardless of how many hubs
you declare — `--@<hub_a>//dep_group=…` and `--@<hub_b>//dep_group=…`
both refer to the same canonical
`@aspect_rules_py//uv/private/constraints/dep_group:dep_group` flag and
take the same value. The hub-local labels are aliases.

The flag's `build_setting_default` is `""`, matching the synthesis
fallback's empty-keyed group for projects without `[dependency-groups]`.
Set the flag explicitly in `.bazelrc` when projects in the hub have
explicit `[dependency-groups]` (none of which can be named `""`):

```
common --@<hub>//dep_group=dev
common:release --@<hub>//dep_group=prod
```

**What's with annotations?** The `uv.lock` format is great, but it's missing
some key information. Such as what requirements apply when performing sdist
builds. Annotations are the current workaround for how to associate such
required but nonstandardized and missing dependency data with requirements.

**Why aren't entrypoints automatically created?** `pip.parse` performs library
installs at repository time, which allows it to inspect the installed files and
detect entrypoints. Because uv does installs using normal build actions it has
no way to see what binaries may be created or what `.dist-info/entry_points.txt`
records exist.

If you need a given entrypoint as a Bazel target, it needs to be manually
declared. In most cases of normal entrypoints this is quite easy. Tools like
`ruff` which distribute binaries as "wheels" are tricky and not yet supported.

## Acknowledgements

- Jeremy Volkman's `rules_pycross` is in a direct precursor and inspiration for
  this tool. They use the same strategy, uv is just able to leverage an off the
  shelf lockfile format which postdates Jeremy's efforts.

- Richard Levasseur and Ignas Anikevicius of `rules_python` have been great
  collaborators and good sports in my treating the `rules_python` authors
  meeting as the bazel-python-sig. Ignas in particular created the marker
  evaluation code which makes uv's conditional dependency activation possible,
  and Richard provided the example for programmable constraints with flags.

This work was made possible by support from Physical Intelligence, the RAI
Institute and others to whom we're grateful.
