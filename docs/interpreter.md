# `aspect_rules_py` Python Interpreters

`aspect_rules_py` provides its own Python interpreter provisioning, backed by
[python-build-standalone](https://github.com/astral-sh/python-build-standalone)
(PBS). This replaces the need to use `rules_python`'s `python.toolchain()` for
interpreter management.

**No version manifests.** Unlike `rules_python`, there is no checked-in table of
SHA256 hashes or version metadata to maintain. Interpreter versions and checksums
are discovered automatically from PBS release artifacts and cached in your
`MODULE.bazel.lock`.

**Easy updates.** To get new interpreter versions, add a PBS release date. That's
it — no repinning, no manifest regeneration.

**No editorial decisions.** We don't decide which Python versions you can use.
Any version published in a PBS release is available. Need Python 3.8? Add an
older release date that includes it.

**Windows and cross-platform support.** Runtime and C toolchains are registered
for nine PBS target platforms, including Windows (x86_64, aarch64, i686), Linux
(glibc and musl), and macOS.

## Quickstart

```starlark
# MODULE.bazel
bazel_dep(name = "aspect_rules_py", version = "1.6.7")  # Or later

interpreters = use_extension("@aspect_rules_py//py:extensions.bzl", "python_interpreters")
interpreters.toolchain(python_version = "3.12", is_default = True)
interpreters.toolchain(python_version = "3.11")
use_repo(interpreters, "python_interpreters")
register_toolchains("@python_interpreters//:all")
```

The extension uses a set of PBS release dates that cover Python 3.8 through
3.15. The newest available build for each requested version is selected
automatically.

## Configuring releases

By default, the extension ships with a small set of release dates covering the
full range of available Python versions. Use `configure()` to pin to specific
releases or to include versions that have been dropped from newer releases:

```starlark
interpreters = use_extension("@aspect_rules_py//py:extensions.bzl", "python_interpreters")
interpreters.configure(
    releases = ["20260303", "20241002"],
)

interpreters.toolchain(python_version = "3.12", is_default = True)
interpreters.toolchain(python_version = "3.8")  # Resolved from 20241002

use_repo(interpreters, "python_interpreters")
register_toolchains("@python_interpreters//:all")
```

Explicit release identifiers use PBS's eight-digit `YYYYMMDD` format. The
special value `latest` resolves to one of those release dates.

When multiple releases contain the same Python minor version, the newest release
is preferred. If that release contains several full versions for one platform
and build configuration, the newest full version is the target. Older full
versions remain available for exact executor companion lookup. Only one
root-module `configure()` tag is allowed. Dependency modules may include any
number of `configure()` tags without error; they are silently ignored.

## Using the latest release

For development workflows where you always want the newest PBS release:

```starlark
interpreters.configure(releases = ["latest"])
```

This resolves to the newest release via the GitHub releases API. Because the
result depends on when it runs, this marks the extension as **non-reproducible**
— Bazel will re-evaluate it on each invocation rather than caching it.

For CI and production builds, prefer explicit release dates.

## Using a mirror or fork

If you host PBS releases on a mirror or maintain your own fork:

```starlark
interpreters.configure(
    releases = ["20260303"],
    base_url = "https://my-mirror.example.com/pbs/releases/download",
)
```

The `base_url` must point to a directory structure matching PBS releases, where
`{base_url}/{date}/SHA256SUMS` and `{base_url}/{date}/{asset}` are valid paths.

## Module scoping

The `configure()` tag, `is_default`, the `pre_release` flag, and additional
toolchain settings are only honored from the root module. This gives the root
module control over the build environment while allowing dependency modules to
declare which Python versions they need.

| Setting                                              | Root module                          | Non-root module    |
| ---------------------------------------------------- | ------------------------------------ | ------------------ |
| `configure()`                                        | Sets release search space and mirror | Silently ignored   |
| `toolchain(python_version = ...)`                    | Adds to global set                   | Adds to global set |
| `toolchain(is_default = True)`                       | Selects the default                  | Silently ignored   |
| `toolchain(pre_release = True)`                      | Honored                              | Silently ignored   |
| `config_settings` and compatibility constraint lists | Honored                              | Silently ignored   |

If a dependency module requests a Python version that isn't available in any
release configured by the root module, the build will fail with a clear error
message identifying which module requested it.

## Selecting Python versions

The extension creates `@python_interpreters//:python_version` with the root
module's selected default. If the root requests one distinct version, that
version is implicitly the default. If it requests multiple distinct versions,
exactly one distinct version must be marked with `is_default = True`. Repeated
tags that normalize to the same `major.minor` may all mark that version as the
default when their toolchain settings agree. Transitive requests never
determine the default.

Requested versions must be either `major.minor` or a complete PBS version:
`major.minor.patch`, `major.minor.patchaN`, `major.minor.patchbN`, or
`major.minor.patchrcN`. The extension validates this grammar before reducing a
request to `major.minor`.

Declaring any root `toolchain()` tag opts the root into Aspect version
selection. Its implicit or explicit default applies while `rules_python`'s
version flag is empty. If the root declares no `toolchain()` tags, the Aspect
default remains empty; transitive requests still provision toolchains, and
`rules_python`'s flag can select among them.

There are three layers of version selection.

### 1. The root default (MODULE.bazel)

```starlark
interpreters.toolchain(python_version = "3.12", is_default = True)
interpreters.toolchain(python_version = "3.14")
```

### 2. An Aspect build-wide version (.bazelrc)

Set `--@aspect_rules_py//py:python_version` in `.bazelrc` to select the version
for Aspect rules and make the choice visible in version control:

```
# .bazelrc
common --@aspect_rules_py//py:python_version=3.12
```

For Aspect rules, this is the build-wide version unless a target sets
`python_version`. In other configurations it is only a fallback while
`rules_python`'s version is empty; it does not lock every target in a mixed
Aspect and `rules_python` graph.

This flag can also be overridden on the command line for one-off testing against
a different version:

```sh
# Quick smoke-test on 3.11 without editing any files
bazel test //... --@aspect_rules_py//py:python_version=3.11
```

### 3. Per-target overrides (python_version attribute)

Individual `py_binary`, `py_venv_binary`, `py_test`, and `py_venv_test` targets
can pin to a specific version using the `python_version` attribute. This takes
precedence over the flag:

```starlark
load("@aspect_rules_py//py:defs.bzl", "py_binary")

py_binary(
    name = "app",
    srcs = ["app.py"],
    python_version = "3.12",
)
```

Use this when a target genuinely requires a specific version — for example a
library that only supports 3.12+, or a test matrix that exercises multiple
versions:

```starlark
[py_venv_test(
    name = "test_py%s" % v.replace(".", ""),
    srcs = ["test.py"],
    main = "test.py",
    python_version = v,
) for v in ["3.11", "3.12", "3.13"]]
```

### Precedence

| Mechanism                               | Scope                                          | Set by                     |
| --------------------------------------- | ---------------------------------------------- | -------------------------- |
| `is_default = True` on `toolchain()`    | Aspect; fallback while rules_python is empty   | `MODULE.bazel`             |
| `--@aspect_rules_py//py:python_version` | Aspect; fallback while rules_python is empty   | `.bazelrc` or command line |
| `python_version` attribute              | Single Aspect target                           | `BUILD.bazel`              |

Aspect rules choose their target attribute first, then the Aspect flag or its
generated root default, and finally `rules_python`'s version flag when the
Aspect value is empty. Their transitions copy the result into both flags.

`rules_python` rules instead set only their own version flag. Any nonempty value
there takes precedence during toolchain selection, so a `rules_python` target's
`python_version` attribute overrides the generated Aspect root default.

## Build configurations

The extension registers one normal PBS build for each available version and
platform. It also registers a free-threaded build when the selected PBS release
publishes that version and platform combination:

- `install_only` is the normal build.
- `freethreaded` is selected with
  `--@aspect_rules_py//py/private/interpreter:freethreaded=true`.

For a target platform, the runtime and C registrations point into the same
repository created from one exact PBS archive. They share target platform,
libc, complete Python version, build configuration, and root-supplied settings.

Target platforms selected from the same PBS release date, complete Python
version, and logical build configuration form a cohort. Exec tools are selected
from that exact cohort for the executor platform. If the release does not
contain the exact companion archive for one executor platform, only that
cohort/executor pairing is omitted; target runtime and C registrations remain
available.

On Linux, only GNU PBS artifacts are registered as exec tools, and Linux
execution platforms must provide glibc. Musl remains supported as a target: a
musl target resolves musl runtime and C toolchains while build actions use GNU
exec tools. `PLATFORM_LIBC_FLAG` is a target configuration setting; it cannot
constrain an execution platform. The generated Linux exec registrations
therefore constrain only OS and CPU. Registering a Linux execution platform is
an explicit promise that its host provides glibc.

Bazel resolves the runtime, C, and exec-tools toolchain types independently.
Each exec registration is constrained to a disjoint target cohort, so a
resolved set uses one release date, complete version, and build configuration.

## Platforms

The following PBS platforms are registered by default:

| Platform                     | OS            | Architecture | Toolchains    |
| ---------------------------- | ------------- | ------------ | ------------- |
| `aarch64-apple-darwin`       | macOS         | ARM64        | Target + exec |
| `x86_64-apple-darwin`        | macOS         | x86_64       | Target + exec |
| `aarch64-unknown-linux-gnu`  | Linux (glibc) | ARM64        | Target + exec |
| `x86_64-unknown-linux-gnu`   | Linux (glibc) | x86_64       | Target + exec |
| `aarch64-unknown-linux-musl` | Linux (musl)  | ARM64        | Target only   |
| `x86_64-unknown-linux-musl`  | Linux (musl)  | x86_64       | Target only   |
| `x86_64-pc-windows-msvc`     | Windows       | x86_64       | Target + exec |
| `aarch64-pc-windows-msvc`    | Windows       | ARM64        | Target + exec |
| `i686-pc-windows-msvc`       | Windows       | x86 (32-bit) | Target + exec |

Not all Python versions are available on all platforms. Unavailable combinations
are silently skipped during toolchain resolution.

## Migrating local interpreters

Version 2 removes the `interpreters.local()` tag. It could pair an arbitrary
runtime with headers and libraries supplied independently, so the extension
could not guarantee that Python extension modules used one ABI-compatible
toolchain. Use `interpreters.toolchain()` for a matched PBS runtime and C
toolchain. Projects that intentionally require a system interpreter can
register it through `rules_python` instead of this extension.

## Compatibility with rules_python

This interpreter provisioning is designed to coexist with `rules_python`:

- The standard `@bazel_tools//tools/python:toolchain_type` is used for toolchain
  registration, so these interpreters work with all existing Python rules.
- A nonempty `@rules_python//python/config_settings:python_version` value takes
  precedence over the generated root default, so `rules_python` per-target
  `python_version` transitions select the requested interpreter. The generated
  `@python_interpreters//:python_version` flag supplies the default while the
  `rules_python` flag is empty.
- Transitions used by this repository set both version flags to the same value,
  so their explicit target version remains authoritative.
- `py_runtime` and `py_runtime_pair` from `rules_python` are used to create
  the runtime providers.

You can migrate incrementally: replace `python.toolchain()` calls with
`interpreters.toolchain()` and remove the `rules_python` interpreter
configuration while keeping everything else.

The interpreter extension is also usable without the `py_binary` and `py_test`
rules in this repository: register `@python_interpreters//:all` and select the
generated flag directly. The compatibility label
`@aspect_rules_py//py:python_version` is a build-setting alias and requires the
extension repository to be imported as `python_interpreters`, as shown above.
Older Bazel releases that do not support setting a build-setting alias must use
`--@python_interpreters//:python_version` instead.
