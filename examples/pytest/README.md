# A pytest entrypoint for Bazel's py_test

With Bazel `py_test`, it requires a single file as the entry point. This repository contains a
template that gets rendered for a particular package and will discover tests automatically in the
same way the `pytest` command-line does.

## How to use

After importing this repository into your `WORKSPACE`, add to your Bazel packages containing
`_test.py` files the following:

```python
load("@aspect_rules_py//py:defs.bzl", "py_pytest_main")

py_pytest_main(name = "__test__")
```

When using this repository together with the Gazelle extension for Python from rules_python, Gazelle
will detect the `__test__` target and produce a `py_test` compatible with it.
