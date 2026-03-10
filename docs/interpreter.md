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

interpreters = use_extension("@aspect_rules_py//py/unstable:extension.bzl", "python_interpreters")
interpreters.toolchain(
    is_default = True,
    python_version = "3.12",
)
interpreters.toolchain(python_version = "3.11")
use_repo(interpreters, "python_interpreters")
register_toolchains("@python_interpreters//:all")
```

That's all you need. The extension uses a set of default PBS release dates that
cover Python 3.8 through 3.15. The newest available build for each requested
version is selected automatically.

## Configuring releases

By default, the extension ships with a small set of release dates covering the
full range of available Python versions. Use `configure()` to pin to specific
releases or to include versions that have been dropped from newer releases:

```starlark
interpreters = use_extension("@aspect_rules_py//py/unstable:extension.bzl", "python_interpreters")
interpreters.configure(
    releases = ["20260303", "20241002"],
)

interpreters.toolchain(python_version = "3.12", is_default = True)
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

The `configure()` tag and the `is_default` / `pre_release` flags on `toolchain()`
are only honored from the root module. This gives the root module full control
over the build environment while allowing dependency modules to declare which
Python versions they need.

| Setting                           | Root module                          | Non-root module    |
| --------------------------------- | ------------------------------------ | ------------------ |
| `configure()`                     | Sets release search space and mirror | Silently ignored   |
| `toolchain(python_version = ...)` | Adds to global set                   | Adds to global set |
| `toolchain(is_default = True)`    | Honored                              | Silently ignored   |
| `toolchain(pre_release = True)`   | Honored                              | Silently ignored   |

If a dependency module requests a Python version that isn't available in any
release configured by the root module, the build will fail with a clear error
message identifying which module requested it.

## Selecting Python versions

There are three layers of version control, from broadest to most specific.

### 1. The default version (MODULE.bazel)

The `is_default = True` toolchain is what Bazel selects when nothing else
overrides it:

```starlark
interpreters.toolchain(python_version = "3.12", is_default = True)
```

### 2. A build-wide default (.bazelrc)

Set `--@aspect_rules_py//py:python_version` in `.bazelrc` to lock the
entire build to a specific version. This is a good practice even when it matches
the `is_default` toolchain — it makes the choice explicit and visible in version
control:

```
# .bazelrc
common --@aspect_rules_py//py:python_version=3.12
```

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

| Mechanism | Scope | Set by |
|---|---|---|
| `is_default = True` on `toolchain()` | Whole build (fallback) | `MODULE.bazel` |
| `--@aspect_rules_py//py:python_version` | Whole build | `.bazelrc` or command line |
| `python_version` attribute | Single target | `BUILD.bazel` |

The most specific wins: attribute > flag > default toolchain.

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
- The `@rules_python//python/config_settings:python_version` flag is kept in
  sync with our own version flag via build transitions.
- `py_runtime` and `py_runtime_pair` from `rules_python` are used to create
  the runtime providers.

You can migrate incrementally: replace `python.toolchain()` calls with
`interpreters.toolchain()` and remove the `rules_python` interpreter
configuration while keeping everything else.
