# Dev Dependencies Example

This example demonstrates how to conditionally include development-only
dependencies (debuggers, test runners, linters, etc.) in a Python binary's
build graph using PEP 735 dependency groups, a Bazel `string_flag`, and
`select()`.

## The Problem

In a typical Python project you have packages needed at runtime (Flask,
SQLAlchemy, …) and packages only useful during development (ipdb, pytest,
coverage, …). You want both importable when iterating locally, but you don't
want them present in a production container image.

## How It Works

### 1. Dependency groups in `pyproject.toml` (PEP 735)

```toml
[project]
dependencies = ["build", "setuptools"]

[dependency-groups]
prod = ["flask"]
dev  = [
    {include-group = "prod"},
    "ipdb",
    "pytest",
]
```

The `dev` group composes `prod` (the runtime deps) with dev-only tools using
PEP 735's `include-group` syntax. `uv lock` resolves all groups into a
single lockfile.

### 2. Venv selection via `.bazelrc`

```
# Default: dev venv, includes ipdb/pytest
common --@pypi//venv=dev

# Release config: prod venv only, enable stamping
common:release --@pypi//venv=prod
common:release --//:mode=prod
common:release --stamp
```

The `--@pypi//venv=` flag controls which dependency group the hub makes
available. The default is `dev` (everything importable). `--config=release`
switches to `prod` (runtime deps only).

### 3. A `string_flag` to control dep inclusion

```starlark
string_flag(
    name = "mode",
    build_setting_default = "dev",
    values = ["dev", "prod"],
)

config_setting(name = "is_dev",  flag_values = {":mode": "dev"})
config_setting(name = "is_prod", flag_values = {":mode": "prod"})
```

### 4. A thin wrapper macro

```starlark
def py_dev_binary(name, deps = [], dev_deps = [], **kwargs):
    py_venv_binary(
        name = name,
        deps = deps + select({
            "//:is_prod": [],
            "//conditions:default": dev_deps,
        }),
        **kwargs
    )
```

In dev mode (the default), `dev_deps` are included. In prod mode the
`select()` resolves to an empty list.

### 5. Using it

```starlark
py_dev_binary(
    name = "app",
    srcs = ["app.py"],
    main = "app.py",
    deps = ["@pypi//flask"],
    dev_deps = [
        "@pypi//ipdb",
        "@pypi//pytest",
    ],
)
```

## Running the example

```sh
cd examples/dev_deps

# Dev mode (default) — ipdb/pytest are available:
bazel run //:app

# Release mode — ipdb/pytest are excluded:
bazel run //:app --config=release
```

## Two coordinated mechanisms

The venv flag and the mode flag work together:

| `.bazelrc` config  | `--@pypi//venv=` | `--//:mode=` | Effect                                                       |
| ------------------ | ---------------- | ------------ | ------------------------------------------------------------ |
| _(default)_        | `dev`            | `dev`        | Hub exposes all packages; `select()` includes dev_deps       |
| `--config=release` | `prod`           | `prod`       | Hub exposes only prod packages; `select()` excludes dev_deps |

The venv flag controls which packages the hub _makes available_ (which wheels
are fetched and linked). The mode flag controls which packages the target
_actually depends on_ via `select()`. Both must agree — the `.bazelrc`
configs keep them in sync.
