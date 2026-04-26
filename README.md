# aspect_rules_py

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
| PEP 735 dependency groups | No                                                                                                      | `--@pypi//venv=prod` flag                                                                                                |

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
- **Lazy downloads**: All fetching happens during the build phase, not repository loading—fully compatible with private
  mirrors and RBE

### Own Python Interpreter Provisioning

`aspect_rules_py` ships its own [python-build-standalone](https://github.com/astral-sh/python-build-standalone)
interpreter extension—rules_python is not required as a toolchain provider.

> [!NOTE]
> The `//py/unstable` and `//uv/unstable` extension paths indicate that the extension API may evolve across
> releases—not that the features are unstable.

```python
interpreters = use_extension("@aspect_rules_py//py/unstable:extension.bzl", "python_interpreters")
interpreters.toolchain(python_version = "3.12", is_default = True)
use_repo(interpreters, "python_interpreters")
register_toolchains("@python_interpreters//:all")
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

- First-class pytest support with `py_pytest_main`
- Automatic test discovery with proper import handling
- Compatible with `pytest-mock`, `pytest-xdist`, and other plugins

## Installation and Configuration

```bzl
bazel_dep(name = "aspect_rules_py", version = "1.11.2")
```

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

## Dependency Resolution with `uv`

`aspect_rules_py//uv` is our alternative to `rules_python`'s `pip.parse`:

```bzl
uv = use_extension("@aspect_rules_py//uv/unstable:extension.bzl", "uv")

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
    post_install_patch_strip = 1,
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
bazel run //:app --@pypi//venv=prod
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

## IDE Integration

`aspect_rules_py` generates standard virtualenv structures that IDEs understand:

```bash
# Creates a .venv symlink for the target
bazel run //:my_app.venv
```

Then point your IDE to the generated virtualenv:

- **VSCode**: Set `python.defaultInterpreterPath` to the `.venv` path
- **PyCharm**: Add the `.venv` as a Python interpreter
- **Neovim/LSP**: Configure `python-lsp-server` or `pyright` to use the virtualenv

### Debugger Support (VSCode/PyCharm)

Attach debuggers using `debugpy`:

```starlark
# In debug mode, wraps the binary with debugpy listener
py_binary(
    name = "app_debug",
    srcs = ["main.py"],
    deps = ["//:lib", "@pypi//debugpy"],
    env = {"DEBUGPY_WAIT": "1"},  # Wait for IDE attachment
)
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
>  When using `pytest_main=True`, you can create a [small wrapper macro](https://github.com/aspect-build/aspect-workflows-template/blob/main/%7B%7B%20.ProjectSnake%20%7D%7D/tools/pytest/defs.bzl) for `py_test` that presets `pytest_main=True` and automatically adds `pytest` as dep.
> Then you need to update ` gazelle:map_kind py_test py_test` to point to your wrapper rule.

## Migration from `rules_python`

`aspect_rules_py` is designed for incremental adoption:

1. **Swap the rules**: Load `py_binary`, `py_library`, `py_test` from `@aspect_rules_py//py:defs.bzl` instead of
   `@rules_python//python:defs.bzl`
2. **Migrate dependencies**: Replace `pip.parse` with `uv.hub` and generate a `uv.lock`
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
- [RAI Institute](https://www.rai.ac/)
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
