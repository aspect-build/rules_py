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
execution platform only when type checking is on.

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

Relative paths in the configuration resolve against the workspace root, as they do when ty runs
there, so one file can serve both the build and your editor. A few differences remain:

- `[[overrides]] include` and `[src] exclude` patterns match the paths Bazel passes to ty, which for
  generated files start with `bazel-out/<config>/bin/`.
- A directory in `[environment] extra-paths` exists in the sandbox only if one of the target's
  inputs is inside it. Prefer `deps` or `pyi_deps` for anything a check should see.
- The build ignores `[environment] python` and `root`: imports resolve only against the target's
  dependencies.

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
Dependencies that carry only `@rules_python`'s `PyInfo`, such as a rules_python `py_library` or
wheel, or protobuf's `py_proto_library`, contribute their import roots too.

Some imports work at runtime but cannot be resolved statically:

- **rules_python's `venvs_site_packages` layout**: wheels installed with it reach the venv through
  `venv_symlinks` rather than import roots, so the checker doesn't see them.
- **`virtual_deps`**: a `py_library` that declares `virtual_deps` is not checked, because the
  packages it imports only exist once a binary resolves them.
- **Packages split between source and generated files**: when a regular (non-PEP 420) package has
  checked-in files and generated ones, such as `_pb2.py` modules generated into it, runfiles merge
  them into one directory, but the checker sees the source tree and the output tree as separate
  search paths and stops at the first `__init__.py`. Imports of the generated modules are then
  unresolved. Generate them into a package of their own, or opt the affected targets out.
- **Packages split across wheels**: when two wheels both ship files under one regular (non-PEP 420)
  package, the venv merges them physically, but the checker sees each wheel's copy separately. Opt
  the affected targets out.
- **Compiled extensions without stubs**: ty does not read `.so` / `.pyd` modules. Ship `.pyi` stubs
  alongside them, for example in `srcs` or `pyi_deps`.
- **Dependency groups**: a library built on its own, outside any binary's `dep_group`, is checked
  against whatever the hub resolves without one, which may be no packages at all. Set a default
  with `--@pypi//dep_group=...`.
