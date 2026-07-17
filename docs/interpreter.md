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

**Native extension toolchains.** Each PBS interpreter repository defines a
`rules_python` C toolchain over that archive's headers and required Windows
import libraries. Regular runtimes also expose stable-ABI headers.
Free-threaded runtimes expose only the full ABI; the `abi3t` ABI introduced
by [PEP 803](https://peps.python.org/pep-0803/) is not yet modeled.

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

Set `--@aspect_rules_py//py:python_version` in `.bazelrc` to lock the
entire build to a specific version and keep the selection explicit in version
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

### 2. Per-target overrides (python_version attribute)

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

| Mechanism                               | Scope                  | Set by                     |
| --------------------------------------- | ---------------------- | -------------------------- |
| `--@aspect_rules_py//py:python_version` | Whole build            | `.bazelrc` or command line |
| `python_version` attribute              | Single target          | `BUILD.bazel`              |

The target attribute takes precedence over the build-wide flag.

## Runtime modes

The extension registers one normal PBS archive for each available Python version
and platform (the archive is chosen by `build_config`, see below). It also
registers an optimized free-threaded archive where PBS publishes one, currently
for Python 3.13 and newer. Normal mode is selected by default. Select
free-threaded mode with the build setting:

```shell
bazel build \
    --@aspect_rules_py//py/private/interpreter:freethreaded=true \
    //...
```

`interpreters.toolchain()` chooses Python versions; the build setting above
selects runtime mode.

## Build configuration

PBS publishes each interpreter in several build configurations. `configure()`
selects which one backs the normal (non-free-threaded) runtime, hub-wide:

```starlark
interpreters.configure(
    releases = ["20260303"],
    build_config = "install_only_stripped",
)
```

Supported values:

| `build_config`          | Description                                            |
| ----------------------- | ------------------------------------------------------ |
| `install_only`          | Optimized, minimal redistributable (default).          |
| `install_only_stripped` | Same as `install_only` with debug symbols removed (smallest download). |
| `<opt>[+<opt>...]-full` | A full archive; each `<opt>` is one of `debug`, `noopt`, `pgo`, `lto`, in that order (e.g. `pgo+lto-full`, `debug-full`). |

Only `install_only` and `install_only_stripped` are published for every platform
listed below, so they are the only configurations usable as a hub-wide default.
Each platform family publishes different `-full` flavors — glibc Linux and macOS
get `debug-full` and `pgo+lto-full`, musl Linux gets `debug-full`, `lto-full`,
and `noopt-full`, and Windows gets only `pgo-full` — and platforms without the
selected archive get no normal-mode toolchain (their interpreter repos still
exist and fetch cleanly, so `use_repo()` imports, `bazel fetch --all`, and
`bazel vendor` keep working, but referencing anything in them fails with an
explanation). A `build_config` that matches no platform at all for a requested
version fails extension evaluation eagerly. `debug-full` comes closest to
hub-wide, covering every platform except Windows. Statically linked (`+static`)
configurations are rejected because extension modules resolve Python symbols from
the loading interpreter. Free-threading is a separate axis selected at build time
(see [Runtime modes](#runtime-modes)), so `build_config` must not name a
`freethreaded` suffix.

`debug-full` produces a `Py_DEBUG` interpreter (ABI flag `d`); PyPI ships no
matching wheels, so C-extension dependencies must be built from source. The
debug property does not carry across the free-threading axis: with a
`debug-full` hub, selecting free-threaded mode still yields the optimized
free-threaded archive (ABI flag `t`, not `td`).

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

All listed PBS platforms emit Python runtime registrations. PBS exec-tools
registrations are emitted only for supported execution platforms: macOS,
Windows, and GNU Linux. PBS-backed Linux exec registrations support glibc; musl
interpreters remain available as Linux target runtimes.

## Compatibility with rules_python

This interpreter provisioning is designed to coexist with `rules_python`:

- The standard `@bazel_tools//tools/python:toolchain_type` is used for toolchain
  registration, so these interpreters work with all existing Python rules.
- The `@rules_python//python/config_settings:python_version` flag is kept in
  sync with our own version flag via build transitions.
- Runtimes registered with `rules_python`'s `py_runtime` / `py_runtime_pair`
  (for example a system interpreter) remain usable by rules_py rules, which
  read the runtime fields structurally.
- Build actions that run an interpreter (wheel installation, site-packages
  merging) resolve `@aspect_rules_py//py/private/toolchain:exec_tools_toolchain_type`,
  registered by `interpreters.toolchain()`. The exec interpreter follows the
  Python version flags when the hub provisions that version; otherwise it
  falls back to the hub's highest provisioned version — including the hub
  rules_py itself registers, so this resolves even in modules that provision
  interpreters only through `rules_python`'s `python.toolchain()`. rules_py
  registers nothing under `rules_python`'s exec-tools type, leaving it —
  including precompiling — entirely to `rules_python`.

Note that runtimes provisioned by `interpreters.toolchain()` carry
`rules_python`'s public `PyRuntimeInfo` (re-exported from
`@aspect_rules_py//py:defs.bzl`), so `rules_python`-defined executables and
their downstream consumers (`py_zipapp_binary`, `py_interpreter`) analyze and
run on them. No coverage tool is bundled, so `rules_python`-rule coverage on
these runtimes is unavailable.

You can migrate incrementally: replace `python.toolchain()` calls with
`interpreters.toolchain()` and remove the `rules_python` interpreter
configuration while keeping everything else.
