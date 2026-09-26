# aspect_rules_py

> [!NOTE]
> This repository uses the [Aspect CLI](https://github.com/aspect-build/aspect-cli) for CI and local development.
> See the [docs](https://docs.aspect.build/cli/overview) and [install instructions](https://docs.aspect.build/cli/install) to get started.

> [!WARNING]
> **This is the 2.x ALPHA branch.** APIs and behavior may change without notice. For stable documentation, see the [1.x branch](https://github.com/aspect-build/rules_py/tree/1.x).

`aspect_rules_py` is a high-performance alternative to [rules_python](https://github.com/bazelbuild/rules_python), the
reference Python ruleset for Bazel.

It provides drop-in replacements for `py_binary`, `py_library`, and `py_test` that prioritize:

- **Blazing-fast dependency resolution** via native `uv` integration
- **Strict hermeticity** with isolated Python execution and Bash-based launchers
- **Idiomatic Python layouts** using standard `site-packages` symlink trees
- **Seamless IDE compatibility** via virtualenv-native structures
- **Production-ready containers** with optimized OCI image layers

`aspect_rules_py` optimizes for modern Python development workflows, large-scale monorepos, and Remote Build Execution (
RBE) environments.

## Advantages Over `rules_python`

| Feature                   | rules_python                                                                                            | rules_py                                                                                                                 |
|:--------------------------|:--------------------------------------------------------------------------------------------------------|:-------------------------------------------------------------------------------------------------------------------------|
| Dependency resolution     | `pip.parse` (repo rules, loading phase)                                                                 | Build-action wheel installs (`whl_install`)                                                                              |
| uv integration            | `uv pip compile` → `requirements.txt` → `pip.parse`                                                     | Native `uv.lock` consumption                                                                                             |
| Cross-platform lockfile   | `requirements.txt` (`uv.lock` via `uv pip compile`)                                                     | Native single `uv.lock` consumption                                                                                      |
| sdist / PEP 517 builds    | Not supported ([#2410](https://github.com/bazel-contrib/rules_python/issues/2410), open since Nov 2024) | Build actions (`pep517_whl`, `pep517_native_whl`)                                                                        |
| Interpreter provisioning  | Download via rules_python extension                                                                     | Own [python-build-standalone](https://github.com/astral-sh/python-build-standalone) extension — no rules_python required |
| Site-packages layout      | Standard `site-packages` layout (flag-enabled)                                                          | Standard `site-packages` symlink tree                                                                                    |
| Cross-compilation         | Limited                                                                                                 | Native platform transitions (e.g. arm64 image on amd64 host)                                                             |
| Virtual dependencies      | No                                                                                                      | `virtual_deps` — swap implementations at binary level                                                                    |
| PEP 735 dependency groups | No                                                                                                      | `--@pypi//dep_group=prod` flag                                                                                                |

> [!NOTE]
> **rules_python's uv support**: `rules_python`'s uv integration runs `uv pip compile` as a build action to
> generate a `requirements.txt`—it is a faster `pip-compile` replacement. The result still feeds into `pip.parse()` →
> `whl_library` repository rules at loading phase. There is no `uv.lock` consumption; the rules_python maintainer has
> [suggested](https://github.com/bazel-contrib/rules_python/discussions/3391) this work belongs in a dedicated project.

### Native `uv.lock` Dependency Resolution

Instead of relying on legacy `pip` machinery, we provide native integration with [uv](https://github.com/astral-sh/uv),
a Rust-native Python package resolver.

- **Build-action installs**: Wheel extraction runs as Bazel execution-phase actions—not repo rules—so they are
  sandboxed and compatible with RBE. Crucially, wheels are no longer resolved against the host machine
  architecture: a single build can fetch and extract wheels for any exec or target platform, enabling true
  cross-platform builds (e.g. building Linux `aarch64` wheels on a macOS `x86_64` host)
- **Native `uv.lock` parsing**: Consumes `uv.lock` directly; no `requirements.txt` generation step
- **Universal lockfiles**: A single `uv.lock` works across all platforms
- **sdist / PEP 517 builds**: Build source distributions as Bazel actions (rules_python has no equivalent;
  [#2410](https://github.com/bazel-contrib/rules_python/issues/2410) open since November 2024)
- **PEP 735 dependency groups**: Define `prod`, `dev`, `test` dependency groups and switch between them with a flag
- **Editable requirements**: Override locked packages with local `py_library` targets via `uv.override_package()`
- **Lazy downloads**: Wheel installation happens during the build phase, not repository loading—fully compatible with private
  mirrors and RBE

### Own Python Interpreter Provisioning

`aspect_rules_py` ships its own [python-build-standalone](https://github.com/astral-sh/python-build-standalone)
interpreter extension—rules_python is not required as a toolchain provider.

> [!NOTE]
> The `//py` and `//uv` extension paths provide stable APIs for interpreter provisioning
> and dependency resolution. They graduated from `//py/unstable` and `//uv/unstable` in rules_py v2.0.0.

```python
interpreters = use_extension("@aspect_rules_py//py:extensions.bzl", "python_interpreters")
interpreters.toolchain(python_version = "3.12")
use_repo(interpreters, "python_interpreters")
register_toolchains("@python_interpreters//:all")
```

```text
# .bazelrc
common --@aspect_rules_py//py:python_version=3.12
```

This enables cross-compilation from any host to any target without host-installed Python, and is the foundation for
correct toolchain selection in RBE environments.

### Idiomatic `site-packages` Layout

We do not manipulate `sys.path` or `$PYTHONPATH`. Instead, we generate a standard `site-packages` directory structure
using symlink trees:

- Prevents module name collisions (e.g., standard library `collections` vs. a transitive dependency named `collections`)
- Matches standard Python expectations—tools just work
- Native IDE compatibility: VSCode, PyCharm, and language servers resolve jump-to-definition correctly into the Bazel
  sandbox

### Strict Sandbox Isolation

- **Isolated mode**: Python executes with `-I` flag, preventing implicit loading of user site-packages or host
  environment variables
- **Hermetic launchers**: Our launcher uses the Bazel Bash toolchain, not the host Python, this ensures 100% hermetic
  execution across local machines and RBE nodes
- **No host Python leakage**: Breaks the implicit dependency on system Python during the boot sequence

### Cross-Platform & Cross-Build Native

- **Effortless cross-compilation**: Build Linux container images from macOS (or vice versa) using standard Bazel
  platform transitions
- **Multi-architecture OCI images**: Native support for building `amd64` and `arm64` container images
- **Platform-agnostic queries**: All hub labels are always available—no more "target incompatible" errors when querying
  on a different OS

### Virtual Dependencies for Monorepos

`virtual_deps` allow external Python dependencies to be specified by package name rather than by label:

- Individual projects within a monorepo can upgrade dependencies independently
- Test against multiple versions of the same dependency
- Swap implementations at the binary level (e.g., use `cowsnake` instead of `cowsay`)

### Production Container Support

Built-in rules for creating optimized container images:

- [`py_image_layer`](py/defs.bzl): Creates layered tar files compatible with `rules_oci`
- Cross-platform builds with automatic platform transitions
- Optimized layer caching—dependencies and application code are separated

### Native Pytest Integration

- First-class pytest support with `py_pytest_test`
- Automatic test discovery with proper import handling
- Compatible with `pytest-mock`, `pytest-xdist`, and other plugins

## Installation and Configuration

```bzl
bazel_dep(name = "aspect_rules_py", version = "1.11.2")
```

### Requirements

The minimum supported Python version is **3.10**. The launcher, test runners, and build
tools that run under your configured interpreter use 3.10 syntax, and CI only exercises
3.10 and newer. Older interpreters can still be fetched via `interpreters.configure()`,
but `py_binary` and `py_test` targets will fail at startup on them.

Some `uv` features need newer versions:

| Feature                                                                                                                 | Python |
| ----------------------------------------------------------------------------------------------------------------------- | ------ |
| Free-threaded interpreters (`freethreaded = True`), [first shipped in CPython 3.13](https://peps.python.org/pep-0703/) | 3.13+  |
| `pyproject.toml` parsing in sdist native-dependency detection (needs stdlib `tomllib`)                                  | 3.11+  |

### Quick Start

Load rules from `aspect_rules_py` in your `BUILD` files:

```starlark
load("@aspect_rules_py//py:defs.bzl", "py_binary", "py_library", "py_test")

py_library(
    name = "lib",
    srcs = ["lib.py"],
    deps = ["@pypi//requests"],
)

py_binary(
    name = "app",
    srcs = ["main.py"],
    main = "main.py",
    deps = [":lib"],
)

py_test(
    name = "test",
    srcs = ["test.py"],
    deps = [":lib"],
)
```

### First-party bytecode

`py_binary` and `py_test` accept `precompile = "off" | "pycache" | "sourceless"`
(`select()` accepted). The default is `off`; `--@aspect_rules_py//py:precompile`
changes it for targets that leave `precompile` unset, and an explicit `precompile` pins the
mode regardless of the flag.

- `off` packages first-party `.py` sources.
- `pycache` packages sources and PEP 3147 `__pycache__` bytecode. The launcher's
  own main runs from source, as CPython consults no cache for it.
- `sourceless` packages colocated first-party `.pyc` files without their source.
  Tracebacks then carry no source lines. The main must be in the `srcs` of the
  venv or of one of its direct first-party deps, which `py_binary` and `py_test`
  arrange; a `py_venv_exec` with any other main fails analysis. `.py` files in `data` are
  payload, not modules: they ship as-is and are never compiled. Listing a file
  in both `srcs` and `data` is unsupported. A directory output in
  `srcs` is likewise never compiled and ships as source.

First-party bytecode carries PEP 552 unchecked-hash headers: Bazel rebuilds a
`.pyc` whenever its source changes, so Python never re-validates it at import.
Editing a source and rerunning a stale `bazel-bin` launcher without rebuilding
therefore runs the old bytecode, where `off` mode would follow the runfiles
symlink to the edit; use `bazel run` or rebuild first. Third-party bytecode
compiled by `whl_install` is configurable through
`--@aspect_rules_py//uv/private/pyc:whl_install_pyc_invalidation_mode`
(`checked-hash` or `timestamp`); first-party bytecode has no such switch.

Bytecode lives at its natural paths beside the source, so a `.py` may be
compiled by one ruleset only: a source listed by both a rules_py `py_library`
and a rules_python `py_library` that precompiles it fails analysis with
conflicting actions under `pycache` and `sourceless`. Leave rules_python
precompilation off for shared sources (see [migrating](docs/migrating.md)).
Compile actions exist only below a launcher that requests bytecode, so
`off` builds declare none and never conflict.

Only `.py` files listed in a `py_*` target's `srcs` by their own file label
(checked-in or generated) and owned by that target's package are compiled.
Files reached through a rule target in `srcs` (`filegroup`, `genrule`,
`py_library`) or borrowed from another package stay source; `sourceless` fails
analysis listing them.

Dependencies built by rules_python rules (`py_proto_library`, unconverted
`py_library` targets) are compiled through an aspect over `deps`; no
rules_python `precompile` setting is needed, and bytecode rules_python does
compile is reused. Packages from a rules_python pip hub are never compiled
and run from source. A rules_python `py_library` keeps its
sources in its own runfiles, so under `sourceless` they ship beside the
bytecode until the library is converted to rules_py.

`--@aspect_rules_py//py:pyc_shards` sets how many `PyCompile` actions each
target gets: `0` (the default) is one action per file, `N` shards a
target's sources by path hash into `N` actions, so `1` compiles the whole
target at once, and `-1` picks the smallest power of two that averages at
most 64 sources per shard. Set it in `.bazelrc` when remote execution makes
per-file actions expensive. When bytecode is requested, sharding requires every `.py` to be listed in exactly one
target's `srcs`; violations surface as Bazel's own analysis error, `file
'pkg/mod.pyc' is generated by these conflicting actions`. Adding or editing a
source recompiles only its shard, except that `-1` reshuffles a target whose
source count crosses a doubling boundary. Sources a srcs-less rules_python
wrapper such as `py_proto_library` forwards are compiled per source regardless,
and must not also be reachable through the wrapped library itself. A repo
that meets that guarantee opts in once:

```
# .bazelrc
build --@aspect_rules_py//py:precompile=sourceless
build --@aspect_rules_py//py:pyc_shards=1
```

Bytecode is compiled by an exec-platform CPython matching the target's cache
tag and feature version (prereleases must match exactly), the default with the
rules_py interpreter hub, so cross-platform builds work out of the box. The
target interpreter never compiles, as it may not run on the build host: other
implementations, and versions without a matching exec interpreter, compile only
through a `pyc_compiler_toolchain_type` toolchain registered for that version,
and otherwise ship as source (`sourceless` then fails analysis). A self-contained
compiler must implement the same
argument-file interface as [`pyc_compile.py`](py/private/pyc_compile.py):

```starlark
load("@aspect_rules_py//py:defs.bzl", "py_pyc_compiler_toolchain")

config_setting(
    name = "python_3_13",
    flag_values = {"@aspect_rules_py//py:python_version": "3.13"},
)

py_pyc_compiler_toolchain(
    name = "python_3_13_pyc_compiler_impl",
    tool = "//tools:pyc_compiler",
)

toolchain(
    name = "python_3_13_pyc_compiler",
    target_settings = [":python_3_13"],
    toolchain = ":python_3_13_pyc_compiler_impl",
    toolchain_type = "@aspect_rules_py//py:pyc_compiler_toolchain_type",
)
```

Then register it in `MODULE.bazel`:

```starlark
register_toolchains("//:python_3_13_pyc_compiler")
```

By default compilation runs one `PyCompile` action per source; see
`pyc_shards` above for fewer, larger actions. The reference compiler is served by a
Bazel persistent worker so the interpreter starts once per worker rather than
per action; size the pool with
`--worker_max_instances=PyCompile=N`. A custom compiler runs as a normal spawn.
Compile actions support path mapping (`--experimental_output_paths=strip`), so
a source compiled in one configuration is a cache hit in every other.

`bazel coverage` runs `sourceless` targets as `pycache`, adding back the sources
coverage.py attributes lines to; `pycache` and `off` are unchanged.

Bytecode is compiled at optimization level 0. Under `pycache` an optimized
interpreter (`-O`/`-OO`, `PYTHONOPTIMIZE`) ignores the cache and runs from
source. Under `sourceless` there is no source, so `-O`/`-OO`
`interpreter_options` and `PYTHONOPTIMIZE` set or inherited by the launcher
or its venv fail analysis. Compilation otherwise runs with the interpreter's
default parser settings: a library's bytecode is shared by every launcher, so
launcher `interpreter_options` that change parsing, such as
`-X int_max_str_digits` or `-W error::SyntaxWarning`, only reach the files
the interpreter still parses itself, which is everything under `off` and a
launcher's own main under `pycache`. Sources that need them must stay in `off`
mode. A cache prefix (`-X pycache_prefix`, `PYTHONPYCACHEPREFIX`) makes
CPython ignore in-tree `__pycache__`, so under `pycache` it recompiles every
import; use `off` or `sourceless` with one.

Because pytest collects `.py` source files, `py_pytest_test` under `sourceless`
keeps its own `srcs` as source beside their bytecode; dependencies stay
sourceless.

`py_image_layer` ships whatever bytecode its binaries carry: set `precompile` on the
`py_binary` (or the global flag) and the image follows. Every binary in one
image must use the same mode.

## Dependency Resolution with `uv`

`aspect_rules_py//uv` is our alternative to `rules_python`'s `pip.parse`:

```bzl
uv = use_extension("@aspect_rules_py//uv:extensions.bzl", "uv")

# 1. Declare a hub (a shared dependency namespace)
uv.declare_hub(
    hub_name = "pypi",
)

# 2. Register projects (lockfiles) into the hub
uv.project(
    hub_name = "pypi",
    lock = "//:uv.lock",
    pyproject = "//:pyproject.toml",
    # Build tools injected for sdist packages that need them (e.g. maturin, setuptools)
    default_build_dependencies = ["build", "setuptools"],
)

# 3a. (Optional) Replace a package with a local Bazel target
uv.override_package(
    name = "some_package",
    lock = "//:uv.lock",
    target = "//third_party/some_package",
)

# 3b. (Optional) Patch an installed wheel's file tree after unpacking
uv.override_package(
    name = "some_other_package",
    lock = "//:uv.lock",
    post_install_patches = ["//third_party/patches:fix_some_other_package.patch"],
)

# 3c. (Optional) Remove bundled tests or other unused wheel content
uv.override_package(
    name = "another_package",
    lock = "//:uv.lock",
    exclude_glob = ["another_package/**/tests/**"],
)

# 3d. (Optional) Restrict a package and its dependents to test targets
uv.override_package(
    name = "pytest-postgresql",
    lock = "//:uv.lock",
    testonly = True,
)

use_repo(uv, "pypi")
```

Requirements are declared in standard `pyproject.toml`:

```toml
[project]
name = "myapp"
version = "1.0.0"
requires-python = ">= 3.11"
dependencies = [
    "requests>=2.28",
    "pydantic>=2.0",
]

[dependency-groups]
dev = ["pytest", "black", "mypy"]
```

Generate the lockfile with uv:

```bash
uv lock
```

Switch between dependency groups:

```bash
# Default: use all dependencies
bazel run //:app

# Use only production dependencies
bazel run //:app --@pypi//dep_group=prod
```

## Virtual Dependencies

Declare virtual dependencies in libraries:

```starlark
py_library(
    name = "greet_lib",
    srcs = ["greet.py"],
    virtual_deps = ["cowsay"],  # Not a label—just a package name
)
```

Resolve them in binaries:

```starlark
py_binary(
    name = "app",
    srcs = ["main.py"],
    deps = [":greet_lib"],
    resolutions = {
        "cowsay": "@pypi//cowsay",
    },
)

# Or use a different implementation!
py_binary(
    name = "app_snake",
    srcs = ["main.py"],
    deps = [":greet_lib"],
    resolutions = {
        "cowsay": "//cowsnake",  # Swapped implementation
    },
)
```

## Container Images

Build optimized OCI images with layer caching:

```starlark
load("@aspect_rules_py//py:defs.bzl", "py_binary", "py_image_layer")
load("@rules_oci//oci:defs.bzl", "oci_image", "oci_load")

py_binary(
    name = "app_bin",
    srcs = ["main.py"],
    deps = ["//:lib"],
)

py_image_layer(
    name = "app_layers",
    binary = ":app_bin",
)

oci_image(
    name = "image",
    base = "@ubuntu",
    tars = [":app_layers"],
    entrypoint = ["/app/app_bin"],
)

oci_load(
    name = "image_load",
    image = ":image",
    repo_tags = ["myapp:latest"],
)
```

Cross-compile for Linux from macOS:

```bash
bazel build //:image --platforms=//platforms:linux_amd64
```

### Layer compression

Layers are written by bsdtar, so any libarchive write filter can compress them:
`none`, `gzip` (the default, level 6), `bzip2`, `xz`, `lzma`, `lzop`, `lz4`,
`lrzip`, `zstd`, and `compress`. The file extension follows the filter, which is
what image tooling reads the layer's media type from.

**The OCI image spec only defines `tar`, `+gzip` and `+zstd` layers**, so those
are the three you can put in an image. `rules_oci` identifies a layer's
compression by sniffing its magic; a codec it cannot sniff is labelled an
uncompressed tar and keeps the *compressed* digest as its `diffid`, which builds
successfully and produces an invalid image. `py_image_layer` and `py_layer_tier`
therefore reject the other filters unless you set `allow_non_oci_layers = True`,
which declares that the tars are going somewhere other than an OCI image.

`py_layer_tier` sets compression for the layers it names — pip packages, the
interpreter, and first-party groups:

```starlark
load("@aspect_rules_py//py:defs.bzl", "py_layer_tier")

py_layer_tier(
    name = "tier",
    groups = {
        "@pip//torch": "heavy",
        "//src/common": "common",
    },
    interpreter_group = "interpreter",
    compression = {
        "heavy": ["zstd", "19"],   # [algorithm, level]
        "common": ["gzip"],        # level omitted: libarchive's default
        "interpreter": ["none"],   # an uncompressed layer
    },
)
```

`py_image_layer` sets compression for the layers it creates itself — the
`groups` tars, the squashed pip layer (`"packages"`), and the source layer
(`"default"`) — and takes precedence over the tier for a group both name:

```starlark
py_image_layer(
    name = "app_layers",
    binary = ":app_bin",
    layer_tier = ":tier",
    group_compression = {"default": ["zstd", "3"]},
)
```

For a different implementation of a codec — `pigz`, a tuned `zstd` — declare a
`py_layer_compressor`. bsdtar pipes the archive through the program, so anything
that reads stdin and writes compressed bytes to stdout works. The `extension` is
how you declare what it emits, and it decides whether the result is OCI-valid:

```starlark
load("@aspect_rules_py//py:defs.bzl", "py_layer_compressor")

py_layer_compressor(
    name = "pigz",
    tool = "//tools:pigz",
    args = ["-11"],
    extension = ".tar.gz",  # gzip bytes, so a valid OCI layer
)

py_layer_tier(
    name = "tier",
    groups = {"@pip//torch": "heavy"},
    compressors = {":pigz": "heavy"},
)
```

A compressor declaring anything other than `.tar`, `.tar.gz` or `.tar.zst` is
treated as non-OCI and needs `allow_non_oci_layers = True` — the program's bytes
are opaque, so the extension is the only claim available about what an image
consumer would find.

`py_image_layer` accepts the same mapping as `group_compressors` for its own
tars. Note that `lzop` and `lrzip` are the two filters libarchive implements by
shelling out to a same-named binary, which a sandboxed action is not guaranteed
to have — prefer a `py_layer_compressor` there.

## IDE Integration

`aspect_rules_py` generates standard virtualenv structures that IDEs understand.
In v2.0 the venv targets that the v1.x docs auto-emitted alongside every
`py_binary` are opt-in — declare them on the targets you actually want your
IDE to follow.

The recommended one-liner:

```starlark
load("@aspect_rules_py//py:defs.bzl", "py_binary")

py_binary(
    name = "my_app",
    srcs = ["main.py"],
    main = "main.py",
    expose_venv_link = True,   # publishes :my_app.venv + :my_app.venv_link
)
```

`expose_venv_link = True` emits two sibling targets:

- `bazel run //:my_app.venv` — drops you into the hermetic interpreter REPL
  with the venv activated. Useful for ad-hoc Python sessions matching your
  binary's deps.
- `bazel run //:my_app.venv_link` — materialises a workspace-local symlink
  pointing at the target's complete runfiles tree and prints the venv's nested
  path below that link. **Point your IDE at the printed venv path.**

Then point your IDE to the virtualenv path printed by the command:

- **VSCode**: Set `python.defaultInterpreterPath` to the printed path
- **PyCharm**: Add the printed venv path as a Python interpreter
- **Neovim/LSP**: Configure `python-lsp-server` or `pyright` to use the virtualenv

### Underlying mechanism

`expose_venv_link = True` is sugar for the explicit two-target shape:

```starlark
py_binary(
    name = "my_app",
    srcs = ["main.py"],
    main = "main.py",
    expose_venv = True,
)

py_venv_link(
    name = "my_app.venv_link",
    venv = ":my_app.venv",
)
```

Reach for the explicit form when you want to customise `py_venv_link`'s
`link_name`, point it at a standalone `py_venv` (declared independently
of any binary, useful for an IDE-only environment), or selectively skip
the link target on a subset of binaries.

> **Migrating from v1.x?** `py_binary` no longer auto-emits a `.venv` sibling.
> Add `expose_venv_link = True` for the equivalent IDE-symlink behavior,
> or use the explicit two-target form when you want fine-grained control. The
> workspace link now points to the complete runfiles tree, so update IDE,
> shell, direnv, and automation paths such as `.venv/bin` to use the nested
> virtualenv path printed by `bazel run :<name>.venv_link`.

### Debugger Support (VSCode/PyCharm)

Attach DAP-compatible debuggers (VSCode, PyCharm, Neovim, etc.) using
[debugpy](https://github.com/microsoft/debugpy). This requires a wrapper
entrypoint that starts a debugpy listener before running your application —
simply adding `debugpy` to `deps` is not enough.

See the [complete debugger example](examples/debugger/) for a working
setup, including a `py_debuggable_binary` macro that handles the wrapper
generation automatically.

Quick overview:

```sh
cd examples/debugger

# Start with debugpy listener, wait for IDE to attach:
DEBUGPY_WAIT=1 bazel run //:app

# Release mode — no debugpy, runs directly:
bazel run //:app --config=release
```

VSCode `launch.json`:

```json
{
  "name": "Attach to Bazel py_binary",
  "type": "debugpy",
  "request": "attach",
  "connect": {
    "host": "127.0.0.1",
    "port": 5678
  }
}
```

## Gazelle Integration

Generate `BUILD` files automatically with the Gazelle extension:

```bzl
# MODULE.bazel
bazel_dep(name = "gazelle", version = "0.42.0")
bazel_dep(name = "aspect_rules_py", version = "1.11.2")

# In your BUILD file
# gazelle:map_kind py_library py_library @aspect_rules_py//py:defs.bzl
# gazelle:map_kind py_binary py_binary @aspect_rules_py//py:defs.bzl
# gazelle:map_kind py_test py_test @aspect_rules_py//py:defs.bzl
```

```bash
# Generate BUILD files
bazel run //:gazelle
```

> [!NOTE]
>  For pytest suites, use `py_pytest_test` (always drives pytest) instead of the generic `py_test`.
> Because Gazelle can't infer the `pytest` dependency for assert-only tests, map `py_test` to a
> thin wrapper that injects it rather than mapping directly — see
> [docs/test-drivers.md](docs/test-drivers.md#gazelle). `py_pytest_test`/`py_unittest_test` require
> a release that includes them (later than the `1.11.2` pinned above).

## Migration from `rules_python`

`aspect_rules_py` is designed for incremental adoption:

1. **Swap the rules**: Load `py_binary`, `py_library`, `py_test` from `@aspect_rules_py//py:defs.bzl` instead of
   `@rules_python//python:defs.bzl`
2. **Migrate dependencies**: Replace `pip.parse` with `uv.declare_hub` and generate a `uv.lock`
3. **Optionally migrate toolchains**: Replace `rules_python` interpreter provisioning with
   the `aspect_rules_py` interpreter extension for fully independent hermetic interpreters

For detailed migration guidance, see [docs/migrating.md](docs/migrating.md).

## Documentation

- [Dependency resolution with `uv`](docs/uv.md)
- [Virtual dependencies](docs/virtual_deps.md)
- [Interpreter configuration](docs/interpreter.md)
- [Migration guide](docs/migrating.md)
- [Contributing](CONTRIBUTING.md)

## Users

- [OpenAI](https://github.com/openai/codex)
- [Physical Intelligence](https://www.physicalintelligence.company/)
- [RAI Institute](https://rai-inst.com/)
- [NVIDIA OSMO](https://github.com/NVIDIA/OSMO)
- [ZML](https://github.com/zml/zml)
- [Eclipse SCORE](https://github.com/eclipse-score/score)
- [Intrinsic](https://github.com/intrinsic-opensource/ros-central-registry)
- [Enfabrica](https://github.com/enfabrica/enkit)
- [ReSim AI](https://github.com/resim-ai/open-core)
- [StackAV](https://github.com/stackav-oss/clockwork)
- [Netherlands Cancer Institute](https://github.com/NKI-AI/direct)
- [pyrovelocity](https://github.com/pyrovelocity/pyrovelocity)

## Architecture

| Layer          | Implementation         | Description                                                                          |
|:---------------|:-----------------------|:-------------------------------------------------------------------------------------|
| **Toolchains** | `@aspect_rules_py//py` | Own python-build-standalone interpreter provisioning; `@rules_python` optional       |
| **Resolution** | `@aspect_rules_py//uv` | Fast, lockfile-backed dependency resolution with `uv`                                |
| **Execution**  | `@aspect_rules_py//py` | Drop-in replacements for `py_binary`, `py_library`, `py_test` with sandbox isolation |
| **Generation** | `aspect-gazelle`       | Pre-compiled Gazelle extension—no CGO toolchain required                             |

## License

Apache 2.0 - see [LICENSE](LICENSE)
