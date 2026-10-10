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

The checker is [ty](https://github.com/astral-sh/ty), downloaded as a prebuilt binary for the
execution platform only when type checking is on. Bazel shows the output of every check that runs,
so a passing check prints ty's `All checks passed!`, along with any warnings.

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

## What the checker sees

A target's search paths mirror its runtime `sys.path`: its import roots (`imports`) and those of
its `deps` and `pyi_deps`, and each wheel's `site-packages`. For `py_binary` and `py_test`, each
source's own directory is also on the path, as the script's directory is for `python main.py`.

Some imports work at runtime but cannot be resolved statically:

- **Dependencies built by other rule sets**: a dep that carries only `@rules_python`'s `PyInfo`,
  such as a rules_python `py_library` or wheel, or protobuf's `py_proto_library`, contributes no
  search paths, so imports from it are unresolved. Opt its consumers out.
- **`virtual_deps`**: a `py_library` that declares `virtual_deps` is not checked, because the
  packages it imports only exist once a binary resolves them.
- **Packages split across wheels**: when two wheels both ship files under one regular (non-PEP 420)
  package, the venv merges them physically, but the checker sees each wheel's copy separately. Opt
  the affected targets out.
- **Compiled extensions without stubs**: ty does not read `.so` / `.pyd` modules. Ship `.pyi` stubs
  alongside them, for example in `srcs` or `pyi_deps`.
- **Dependency groups**: a library built on its own, outside any binary's `dep_group`, is checked
  against whatever the hub resolves without one, which may be no packages at all. Set a default
  with `--@pypi//dep_group=...`.
