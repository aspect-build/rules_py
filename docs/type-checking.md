# Type checking

`py_library`, `py_binary` and `py_test` can type check their sources as part of the build. It's off
by default; turn it on with:

```
# .bazelrc
common --@aspect_rules_py//py:type_check
```

The check is a [validation action](https://bazel.build/extending/rules#validation_actions), so it
runs whenever a target is built or tested, and a type error fails the build:

```
ERROR: //app:lib: Type checking //app:lib failed: ...
app/lib.py:3:14: error[invalid-assignment] Object of type `int` is not assignable to `str`
```

Each target checks only its own `srcs`, and targets in external repositories are not checked.

The default checker is [ty](https://github.com/astral-sh/ty), downloaded as a prebuilt binary
for the execution platform.

## Opting out

With type checking on, opt one target out:

```starlark
py_library(
    name = "legacy",
    srcs = ["legacy.py"],
    type_check = False,
)
```

`--norun_validations` skips type checking along with every other validation action.

## Configuration

Point the checker at a configuration file, such as a `ty.toml`:

```
# .bazelrc
common --@aspect_rules_py//py:type_check_config=//:ty.toml
```

ty does not discover a `pyproject.toml` or `ty.toml` on its own inside the build, and it never reads
per-user configuration, so set this flag to apply project settings. The target Python version comes
from the resolved interpreter toolchain.

Only error-level diagnostics fail the build; warnings do not. To make a rule fail the build, raise
it to an error in the configuration file:

```toml
# ty.toml
[rules]
deprecated = "error"
```

To use a different ty release, set the version on the `rules_py_tools` tag:

```starlark
tools = use_extension("@aspect_rules_py//py:extensions.bzl", "py_tools")
tools.rules_py_tools(ty_version = "0.0.84")
```

## Type-check-only dependencies

Imports guarded by `typing.TYPE_CHECKING` resolve against `pyi_deps`, which reach the checker but
never the runnable program:

```starlark
py_library(
    name = "typed",
    srcs = ["typed.py"],
    pyi_deps = ["@pypi//types_requests"],
)
```

A package that ships no stubs, or that defines its API at runtime where a checker cannot see it, can
be described with your own `.pyi` files in a `py_library` passed through `pyi_deps`. Search paths
from `pyi_deps` come first, so these stubs take precedence over the package itself:

```starlark
# stubs/cowsay/__init__.pyi declares the functions cowsay creates at import time.
py_library(
    name = "cowsay_stubs",
    srcs = ["stubs/cowsay/__init__.pyi"],
    imports = ["stubs"],
)

py_binary(
    name = "app",
    srcs = ["app.py"],
    pyi_deps = [":cowsay_stubs"],
    deps = ["@pypi//cowsay"],
)
```

A stub directory stands in for the whole package, so declare every module and name your code uses.

## Using a different type checker

Register a `py_type_checker_toolchain`. A toolchain registered in your root `MODULE.bazel`, or
passed with `--extra_toolchains`, takes precedence over the default ty toolchain. For example, mypy
from your lockfile:

```starlark
# tools/mypy/BUILD.bazel
load("@aspect_rules_py//py:defs.bzl", "py_binary", "py_type_checker_toolchain")

py_binary(
    name = "mypy",
    srcs = ["mypy_main.py"],
    main = "mypy_main.py",
    deps = ["@pypi//mypy"],
)

py_type_checker_toolchain(
    name = "mypy_impl",
    checker = ":mypy",
    args = ["--no-error-summary", "--cache-dir={scratch}"],
    config = "//:mypy.ini",
    config_flag = "--config-file",
    python_version_flag = "--python-version",
    search_path_env = "MYPYPATH",
)

toolchain(
    name = "mypy_toolchain",
    target_settings = ["@aspect_rules_py//py:type_check_enabled"],
    toolchain = ":mypy_impl",
    toolchain_type = "@aspect_rules_py//py:type_checker_toolchain_type",
)
```

```starlark
# MODULE.bazel
register_toolchains("//tools/mypy:mypy_toolchain")
```

Gate the `toolchain` on `@aspect_rules_py//py:type_check_enabled` as shown. rules_py builds the
checker with type checking turned off, and the setting keeps the checker's own Python targets from
resolving the toolchain that depends on them, which Bazel would report as a dependency cycle.

rules_py runs the checker as

```
<checker> <args> [<python_version_flag> X.Y] [<config_flag> <config>]
          [<search_path_flag> <path>]... <srcs>...
```

with search paths passed through `search_path_env` instead when that's set. The checker must exit
non-zero when it finds an error. Two placeholders are substituted in `args` and `env`:

- `{scratch}`: an empty directory private to the invocation, for caches and the like.
- `{empty_python_prefix}`: a Python installation layout for the target version with an empty
  `site-packages`. Point the checker's interpreter or environment option at it, so it does not fall
  back to the host's installed packages. A target whose Python version is unknown, because no
  interpreter toolchain resolved for it, is not checked by a toolchain that uses this placeholder.

A checker whose command line does not fit this shape can be wrapped in a small binary that does.

## What the checker sees

A target's search paths mirror its runtime `sys.path`: its import roots (`imports`) and those of
its `deps` and `pyi_deps`, each wheel's `site-packages`, and the root of every external repository.
For `py_binary` and `py_test`, each source's own directory is also on the path, as the script's
directory is for `python main.py`.

Some imports work at runtime but cannot be resolved statically:

- **`virtual_deps`**: a `py_library` that declares `virtual_deps` is not checked, because the
  packages it imports only exist once a binary resolves them.
- **Packages split across wheels**: when two wheels both ship files under one regular (non-PEP 420)
  package, the venv merges them physically, but the checker sees each wheel's copy separately. Opt
  the affected targets out.
- **Compiled extensions without stubs**: ty does not read `.so` / `.pyd` modules. Ship `.pyi` stubs
  alongside them, for example in `srcs` or `pyi_deps`.
- **Generated protobuf code without stubs**: protobuf builds message classes at runtime, so the
  checker needs the `_pb2.pyi` stubs that `protoc --pyi_out` writes. protobuf's own
  `py_proto_library` provides them; rules that only generate `_pb2.py`, such as
  rules_proto_grpc_python's `python_proto_library`, do not, so opt their consumers out.
- **Dependency groups**: a library built on its own, outside any binary's `dep_group`, is checked
  against whatever the hub resolves without one, which may be no packages at all. Set a default
  with `--@pypi//dep_group=...`.

## Requirements

The checker runs under rules_py's exec-configuration interpreter toolchain, which rules_py's
`python_interpreters` extension registers. Builds that use only other interpreter toolchains need to
register rules_py's interpreters, or turn type checking off.
