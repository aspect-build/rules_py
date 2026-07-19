# A pytest entrypoint for Bazel's py_test

> [!NOTE]
> For most pytest suites, prefer `py_pytest_test`, which always drives pytest and
> wires up discovery for you. The `py_pytest_main` flow below is the low-level
> escape hatch — use it for hand-written or wrapped entrypoints. See
> [docs/test-drivers.md](../../docs/test-drivers.md).

With Bazel `py_test`, it requires a single file as the entry point. This repository contains a
template that gets rendered for a particular package and will discover tests automatically in the
same way the `pytest` command-line does.

## How to use

After adding `aspect_rules_py` as a `bazel_dep` in your `MODULE.bazel`, add the following to your
Bazel packages which contain `_test.py` files:

```python
load("@aspect_rules_py//py:defs.bzl", "py_pytest_main")

py_pytest_main(
    name = "__test__",
    deps = ["@pypi//pytest"], # change this to the pytest target in your repo.
)
```

When using this repository together with the Gazelle extension for Python from rules_python, Gazelle
will detect the `__test__` target and produce a `py_test` compatible with it.
