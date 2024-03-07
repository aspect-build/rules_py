# Aspect's Bazel rules for Python

`aspect_rules_py` is a layer on top of `rules_python`, the standard Python ruleset hosted at
https://github.com/bazelbuild/rules_python.
The lower layer of `rules_python` is currently reused, dealing with the toolchain and dependencies.

However, this ruleset introduces a new implementation of `py_library`, `py_binary`, and `py_test`.
Our philosophy is to behave more like idiomatic python ecosystem tools, where rules_python is closely
tied to the way Google does Python development in their internal monorepo, google3.

| Layer                                       | Legacy       | Recommended      |
| ------------------------------------------- | ------------ | ---------------- |
| rules: BUILD file UI                        | rules_python | **rules_py**     |
| gazelle: generate BUILD files               | rules_python | rules_python [1] |
| pip_parse: fetch and install deps from pypi | rules_python | rules_python     |
| toolchain: fetch hermetic interpreter       | rules_python | rules_python     |

_Need help?_ This ruleset has support provided by https://aspect.dev.

[1] we will likely fork the extension for performance, using TreeSitter to parse Python code rather than a Python program.

## Differences

We think you'll love rules_py because:

- The launcher uses the Bash toolchain rather than Python, so we have no dependency on a system interpreter. Fixes:
  - [py_binary with hermetic toolchain requires a system interpreter](https://github.com/bazelbuild/rules_python/issues/691)
- We don't mess with the Python `sys.path`/`$PYTHONPATH`. Instead we use the standard `site-packages` folder layout produced by `pip_install`. This avoids problems like package naming collisions with built-ins (e.g. `collections`) or where `argparse` comes from a transitive dependency instead. Fixes:
  - [Issues with PYTHONPATH resolution in recent python/rules_python versions](https://github.com/bazelbuild/rules_python/issues/1221)
- We run python in isolated mode so we don't accidentally break out of Bazel's action sandbox. Fixes:
  - [pypi libraries installed to system python are implicitly available to builds](https://github.com/bazelbuild/rules_python/issues/27)
  - [sys.path[0] breaks out of runfile tree.](https://github.com/bazelbuild/rules_python/issues/382)
  - [User site-packages directory should be ignored](https://github.com/bazelbuild/rules_python/issues/1059)
- We create a python-idiomatic virtualenv to run actions, which means better compatibility with userland implementations of [importlib](https://docs.python.org/3/library/importlib.html).
- Thanks to the virtualenv, you can open the project in an editor like PyCharm and have working auto-complete, jump-to-definition, etc. Fixes:
  - [Smooth IDE support for python_rules](https://github.com/bazelbuild/rules_python/issues/1401)

> [!NOTE]
> What about the "starlarkification" effort in rules_python?
>
> We think this is only useful within Google, because the semantics of the rules will remain identical.
> Even though the code will live in bazelbuild/rules_python rather than
> bazelbuild/bazel, it still cannot change without breaking Google-internal usage, and has all the ergonomic bugs
> above due to the way the runtime is stubbed.

## Installation

Follow instructions from the release you wish to use:
<https://github.com/aspect-build/rules_py/releases>

### Using with Gazelle

In any ancestor `BUILD` file of the Python code, add these lines to instruct [Gazelle] to create rules_py variants of the `py_*` rules:

```
# gazelle:map_kind py_library py_library @aspect_rules_py//py:defs.bzl
# gazelle:map_kind py_binary py_binary @aspect_rules_py//py:defs.bzl
# gazelle:map_kind py_test py_test @aspect_rules_py//py:defs.bzl
```

[Gazelle]: https://github.com/bazelbuild/rules_python/blob/main/gazelle/README.md
