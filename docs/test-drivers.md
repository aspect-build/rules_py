# Test framework drivers

`rules_py` provides purpose-oriented test macros so each framework has its own
entry point, rather than a single overloaded `py_test`.

## Macros

| Macro | Driver |
| --- | --- |
| `py_test` | generic — runs a Python file as a test |
| `py_pytest_test` | pytest |
| `py_unittest_test` | stdlib `unittest` |
| `py_pytest_main` | low-level pytest entrypoint codegen (escape hatch) |

`py_test` is strictly generic: it runs a Python file as a test, nothing more.
`py_pytest_test` is the pytest driver and `py_unittest_test` the unittest
driver. `py_pytest_main` is the low-level escape hatch for hand-written /
wrapped entrypoints (e.g. exposing `main()` for custom setup-teardown) — those
run as a generic `py_test` with an explicit `main`.

## pytest

```starlark
load("@aspect_rules_py//py:defs.bzl", "py_pytest_test")

py_pytest_test(
    name = "test_foo",
    srcs = ["foo_test.py"],
    deps = ["@pypi_pytest//:pkg"],
)
```

Include the `pytest` package (and `coverage`, for coverage) in `deps`. Baked
pytest args or a working directory go on the `pytest_args` / `chdir`
attributes; runtime args (forwarded to `sys.argv`) go on the standard `args`
attribute.

Every file in `srcs` is a test module that pytest collects — collection is
scoped to the target's own `srcs`, not the whole runfiles tree. Put importable
support code in `deps` and pytest's `conftest.py` in `data`. To select tests by
name pattern, use Bazel's own `glob()`:

```starlark
py_pytest_test(
    name = "tests",
    srcs = glob(["*_test.py", "test_*.py"]),
    data = ["conftest.py"],
    deps = ["@pypi_pytest//:pkg"],
)
```

### Gazelle

Don't map `py_test` directly to `py_pytest_test`. Gazelle only adds `pytest` to
`deps` when a test imports it, but an assert-only test never does — and
`py_pytest_test` always needs `pytest`. Instead map to a thin wrapper that
injects the dependency (and drops the `main` Gazelle sets, since the driver
provides its own entrypoint):

```starlark
# tools/pytest/defs.bzl
load("@aspect_rules_py//py:defs.bzl", _py_pytest_test = "py_pytest_test")

def py_test(name, **kwargs):
    kwargs.pop("main", None)  # py_pytest_test provides its own entrypoint
    deps = kwargs.pop("deps", [])
    if "@pypi//pytest" not in deps:
        deps = deps + ["@pypi//pytest"]
    _py_pytest_test(name = name, deps = deps, **kwargs)
```

```
# gazelle:map_kind py_test py_test //tools/pytest:defs.bzl
```

## unittest

```starlark
load("@aspect_rules_py//py:defs.bzl", "py_unittest_test")

py_unittest_test(
    name = "test_foo",
    srcs = ["foo_test.py"],
)
```

Loads each `srcs` file directly — one import per file, under a path-derived
module name — and collects its `unittest.TestCase`s. It never calls
`discover()`, so nested directories are never re-run and same-basename files in
different directories don't collide. Integrates with Bazel coverage, sharding,
JUnit XML, and `--test_filter`, with no third-party runner required; `coverage`
is needed only for coverage.

Every file in `srcs` is a test module. Put importable support code in `deps`;
to select tests by name pattern, use Bazel's own `glob()` in `srcs` (as shown
for pytest above).

Runtime `args` (forwarded to `sys.argv`) are parsed by the driver:
`-v`/`-q`/(default) select unittest's verbose/quiet/normal output, `-f`/`--failfast`
(also honoring Bazel's `--test_runner_fail_fast`), `-b`/`--buffer`, and `-k
PATTERN` — native unittest `-k`: repeatable and ORed, with `*` matched by
fnmatch (a wildcard-free pattern is a substring match). Bazel's `--test_filter`
narrows further (ANDed as a substring over the test id). Unknown args are
rejected rather than silently ignored, and a filter that matches no tests fails
the run, matching pytest's "no tests collected" behavior.
