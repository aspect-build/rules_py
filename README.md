# aspect_rules_py

`aspect_rules_py` is a high-performance alternative to [rules_python](https://github.com/bazelbuild/rules_python), the
reference Python ruleset for Bazel.

It provides drop-in replacements for `py_binary`, `py_library`, and `py_test` that prioritize:

- **Blazing-fast dependency resolution** via native `uv` integration
- **Strict hermeticity** with isolated Python execution and Bash-based launchers
- **Idiomatic Python layouts** using standard `site-packages` symlink trees
- **Seamless IDE compatibility** via virtualenv-native structures
- **Production-ready containers** with optimized OCI image layers

Unlike `rules_python`, which maintains strict compatibility with Google's internal monorepo semantics (google3),
`aspect_rules_py` optimizes for modern Python development workflows, large-scale monorepos, and Remote Build Execution (
RBE) environments.

## Advantages Over `rules_python`

### Lightning-Fast Dependency Resolution with `uv`

Instead of relying on legacy `pip` machinery, we provide native integration with [uv](https://github.com/astral-sh/uv),
a Rust-native Python package resolver.

- **Sub-second resolution**: Lockfile-backed dependency installation at Rust speeds
- **Universal lockfiles**: A single `uv.lock` works across all platforms—no more `requirements_linux.txt`,
  `requirements_mac.txt`, `requirements_windows.txt`
- **PEP 735 dependency groups**: Define `prod`, `dev`, `test` dependency groups and switch between them with a flag
- **Editable requirements**: Override locked packages with local `py_library` targets via `uv.override_package()`
- **Lazy downloads**: All fetching happens during the build phase, not repository loading—fully compatible with private
  mirrors and RBE

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
- **Hermetic launchers**: Our launcher uses the Bazel Bash toolchain, not the host Python—ensuring 100% hermetic
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
bazel_dep(name = "aspect_rules_py", version = "1.6.7")
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
)

# 3. (Optional) Override packages with local targets
uv.override_package(
    name = "some_package",
    lock = "//:uv.lock",
    target = "//third_party/some_package",
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
bazel_dep(name = "aspect_rules_py", version = "1.6.7")

# In your BUILD file
# gazelle:map_kind py_library py_library @aspect_rules_py//py:defs.bzl
# gazelle:map_kind py_binary py_binary @aspect_rules_py//py:defs.bzl
# gazelle:map_kind py_test py_test @aspect_rules_py//py:defs.bzl
```

```bash
# Generate BUILD files
bazel run //:gazelle
```

## Migration from `rules_python`

`aspect_rules_py` is designed for incremental adoption:

1. **Keep `rules_python` toolchains**: We reuse `rules_python` for hermetic Python interpreter fetching
2. **Swap the rules**: Load `py_binary`, `py_library`, `py_test` from `@aspect_rules_py//py:defs.bzl` instead of
   `@rules_python//python:defs.bzl`
3. **Migrate dependencies**: Replace `pip.parse` with `uv.hub` and generate a `uv.lock`

For detailed migration guidance, see [docs/migrating.md](docs/migrating.md).

## Documentation

- [Dependency resolution with `uv`](docs/uv.md)
- [Virtual dependencies](docs/virtual_deps.md)
- [Interpreter configuration](docs/interpreter.md)
- [Migration guide](docs/migrating.md)
- [Contributing](CONTRIBUTING.md)

## Users

- [Aspect CLI](https://github.com/aspect-build/aspect-cli)
- [OpenAI Codex](https://github.com/openai/codex)
- [DataDog Agent](https://github.com/DataDog/datadog-agent)

## Architecture

| Layer          | Implementation         | Description                                                                          |
|:---------------|:-----------------------|:-------------------------------------------------------------------------------------|
| **Toolchains** | `@rules_python`        | Hermetic Python interpreter fetching and registration                                |
| **Resolution** | `@aspect_rules_py//uv` | Fast, lockfile-backed dependency resolution with `uv`                                |
| **Execution**  | `@aspect_rules_py//py` | Drop-in replacements for `py_binary`, `py_library`, `py_test` with sandbox isolation |
| **Generation** | `aspect-gazelle`       | Pre-compiled Gazelle extension—no CGO toolchain required                             |

## License

Apache 2.0 - see [LICENSE](LICENSE)
