# Type checking

`py_library`, `py_binary` and `py_test` type check their sources as part of the build. The check is a
[validation action](https://bazel.build/extending/rules#validation_actions), so it runs whenever a
target is built or tested, and a type error fails the build:

```
ERROR: //app:lib: Type checking //app:lib failed: ...
app/lib.py:3:14: error[invalid-assignment] Object of type `int` is not assignable to `str`
```

Each target checks only its own `srcs`. Its `deps`, `pyi_deps`, and third-party wheels are visible
to the checker as import search paths, so results cache per target and a change only rechecks the
targets it can affect. Targets in external repositories aren't checked.

The default checker is [ty](https://github.com/astral-sh/ty), downloaded as a prebuilt binary
for the execution platform.

## Turning it off

For the whole build:

```
# .bazelrc
common --@aspect_rules_py//py:type_check=false
```

When the flag is off, ty isn't downloaded at all.

For one target:

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

ty doesn't discover a `pyproject.toml` or `ty.toml` on its own inside the build, and it never reads
per-user configuration, so set this flag to apply project settings. The target Python version comes
from the resolved interpreter toolchain.

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

## Using a different type checker

Register a `py_type_checker_toolchain`. A toolchain registered in your root `MODULE.bazel`, or
passed with `--extra_toolchains`, takes precedence over the default ty toolchain. For example, mypy
from your lockfile:

```starlark
# tools/mypy/BUILD.bazel
load("@aspect_rules_py//py:defs.bzl", "py_binary", "py_type_checker_toolchain")

py_binary(
    name = "mypy",
    srcs = ["mypy_main.py"],  # from mypy.__main__ import console_entry; console_entry()
    main = "mypy_main.py",
    type_check = False,
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
    toolchain = ":mypy_impl",
    toolchain_type = "@aspect_rules_py//py:type_checker_toolchain_type",
)
```

```starlark
# MODULE.bazel
register_toolchains("//tools/mypy:mypy_toolchain")
```

rules_py runs the checker as

```
<checker> <args> [<python_version_flag> X.Y] [<config_flag> <config>]
          [<search_path_flag> <path>]... <srcs>...
```

with search paths passed through `search_path_env` instead when that's set. The checker must exit
non-zero when it finds an error. Two placeholders are substituted in `args` and `env`:

- `{scratch}`: an empty directory private to the invocation, for caches and the like.
- `{empty_python_prefix}`: a Python installation layout for the target version with an empty
  `site-packages`. Point the checker's interpreter or environment option at it, so it doesn't fall
  back to the host's installed packages.

A checker whose command line doesn't fit this shape can be wrapped in a small binary that does.

## What the checker sees

A target's search paths mirror its runtime `sys.path`: its import roots (`imports`) and those of
its `deps` and `pyi_deps`, each wheel's `site-packages`, and the root of every external repository
(so `import bazel_tools.tools.python.runfiles` resolves). For `py_binary` and `py_test`, each
source's own directory is also on the path, as the script's directory is for `python main.py`.

Some imports work at runtime but can't be resolved statically:

- **`virtual_deps`**: a `py_library` that declares `virtual_deps` isn't checked, because the
  packages it imports only exist once a binary resolves them.
- **Packages split across wheels**: when two wheels both ship files under one regular (non-PEP 420)
  package, the venv merges them physically, but the checker sees each wheel's copy separately. Opt
  the affected targets out.
- **Compiled extensions without stubs**: ty doesn't read `.so` / `.pyd` modules. Ship `.pyi` stubs
  alongside them, for example in `srcs` or `pyi_deps`.
- **Dependency groups**: a library built on its own, outside any binary's `dep_group`, is checked
  against whatever the hub resolves without one, which may be no packages at all. Set a default
  with `--@pypi//dep_group=...`.

## Requirements

The checker runs under rules_py's exec-configuration interpreter toolchain, which rules_py's
`python_interpreters` extension registers. Builds that use only other interpreter toolchains need to
register rules_py's interpreters, or turn type checking off.
