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

**Windows and cross-platform support.** 9 platforms are registered out of the
box, including Windows (x86_64, aarch64, i686), Linux (glibc and musl), and
macOS.

## Quickstart

```starlark
# MODULE.bazel
bazel_dep(name = "aspect_rules_py", version = "1.6.7")  # Or later

interpreters = use_extension("@aspect_rules_py//py:extensions.bzl", "python_interpreters")
interpreters.toolchain(
    python_version = "3.12",
)
interpreters.toolchain(python_version = "3.11")
use_repo(interpreters, "python_interpreters")
register_toolchains("@python_interpreters//:all")
```

Select the build-wide Python version in `.bazelrc`:

```text
common --@aspect_rules_py//py:python_version=3.12
```

That's all you need. The extension uses a set of default PBS release dates that
cover Python 3.8 through 3.15. The newest available build for each requested
version is selected automatically.

## Configuring releases

By default, the extension ships with a small set of release dates covering the
full range of available Python versions. Use `configure()` to pin to specific
releases or to include versions that have been dropped from newer releases:

```starlark
interpreters = use_extension("@aspect_rules_py//py:extensions.bzl", "python_interpreters")
interpreters.configure(
    releases = ["20260303", "20241002"],
)

interpreters.toolchain(python_version = "3.12")
interpreters.toolchain(python_version = "3.8")  # Resolved from 20241002

use_repo(interpreters, "python_interpreters")
register_toolchains("@python_interpreters//:all")
```

When multiple releases contain the same Python minor version, the newest release
is preferred. Only one `configure()` tag is allowed per module graph, and only
the root module's tag is honored — dependency modules may include `configure()`
without error, but it will be silently ignored.

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

The `configure()` tag and the `pre_release` flag on `toolchain()` are only
honored from the root module. This gives the root module full control over the
build environment while allowing dependency modules to declare which Python
versions they need.

| Setting                           | Root module                          | Non-root module    |
| --------------------------------- | ------------------------------------ | ------------------ |
| `configure()`                     | Sets release search space and mirror | Silently ignored   |
| `toolchain(python_version = ...)` | Adds to global set                   | Adds to global set |
| `toolchain(pre_release = True)`   | Honored                              | Silently ignored   |

If a dependency module requests a Python version that isn't available in any
release configured by the root module, the build will fail with a clear error
message identifying which module requested it.

## Selecting Python versions

There are two layers of version control, from broadest to most specific.

### 1. A build-wide version (.bazelrc)

Set the public rules_py version flag in `.bazelrc` to keep the build-wide
selection explicit in version control:

```
# .bazelrc
common --@aspect_rules_py//py:python_version=3.12
```

This flag can also be overridden on the command line for one-off testing
against a different version:

```sh
# Quick smoke-test on 3.11 without editing any files
bazel test //... --@aspect_rules_py//py:python_version=3.11
```

This public target aliases the `rules_python` version setting, so both rule
sets observe the same build-wide value and target-specific transitions. If the
flag is unset, the default configured by `rules_python` determines selection.
Registering an interpreter with `interpreters.toolchain()` makes it available;
it does not change that default.

### 2. Per-target overrides (python_version attribute)

Individual `py_binary`, `py_venv_binary`, `py_test`, and `py_venv_test` targets
can pin to a specific version using the `python_version` attribute. Its target
transition overrides the build-wide value for that target:

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

### Selection

| Mechanism                               | Scope         | Set by                     |
| --------------------------------------- | ------------- | -------------------------- |
| `--@aspect_rules_py//py:python_version` | Whole build   | `.bazelrc` or command line |
| `python_version` attribute              | Single target | `BUILD.bazel`              |

Both mechanisms write the canonical
`@rules_python//python/config_settings:python_version` setting. Matching uses
its derived major/minor value, so `3.12.4` selects a `3.12` toolchain rather
than pinning a specific PBS patch artifact.

## Build configurations

PBS provides several build configurations. The default is `install_only`, which
is PGO+LTO optimized on platforms that support it. You can select a different
configuration per toolchain:

```starlark
interpreters.toolchain(
    python_version = "3.12",
    build_config = "install_only_stripped",  # Smaller, debug symbols removed
)
```

Available configurations:

- `install_only` — Standard optimized build (default)
- `install_only_stripped` — Same but with debug symbols stripped
- `freethreaded+pgo+lto` — Free-threaded (no GIL) with PGO+LTO optimization
- `freethreaded+debug` — Free-threaded debug build

## Platforms

The following platforms are registered by default:

| Platform                     | OS            | Architecture |
| ---------------------------- | ------------- | ------------ |
| `aarch64-apple-darwin`       | macOS         | ARM64        |
| `x86_64-apple-darwin`        | macOS         | x86_64       |
| `aarch64-unknown-linux-gnu`  | Linux (glibc) | ARM64        |
| `x86_64-unknown-linux-gnu`   | Linux (glibc) | x86_64       |
| `aarch64-unknown-linux-musl` | Linux (musl)  | ARM64        |
| `x86_64-unknown-linux-musl`  | Linux (musl)  | x86_64       |
| `x86_64-pc-windows-msvc`     | Windows       | x86_64       |
| `aarch64-pc-windows-msvc`    | Windows       | ARM64        |
| `i686-pc-windows-msvc`       | Windows       | x86 (32-bit) |

Not all Python versions are available on all platforms. Unavailable combinations
are silently skipped during toolchain resolution.

## Compatibility with rules_python

This interpreter provisioning is designed to coexist with `rules_python`:

- The standard `@bazel_tools//tools/python:toolchain_type` is used for toolchain
  registration, so these interpreters work with all existing Python rules.
- `@aspect_rules_py//py:python_version` aliases the canonical `rules_python`
  setting, and both projects' target transitions update that shared setting.
- `py_runtime` and `py_runtime_pair` from `rules_python` are used to create
  the runtime providers.

You can migrate incrementally: replace explicit root `python.toolchain()` calls
with `interpreters.toolchain()` while keeping everything else. Set the public
version flag explicitly when the desired version differs from the transitive
`rules_python` default.
