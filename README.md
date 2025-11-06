# Aspect's Bazel rules for Python

`aspect_rules_py` is a layer on top of [rules_python](https://github.com/bazel-contrib/rules_python), the reference Python ruleset.

The lower layer of `rules_python` is currently reused, dealing with interpreter toolchains and other details.

However, this ruleset introduces new implementations of `py_library`, `py_binary`, `py_test` and now `uv`.
Our philosophy is to behave more like idiomatic python ecosystem tools, where rules_python is closely
tied to the way Google does Python development in their internal monorepo, google3.
However we try to maintain compatibility with rules_python's rules for most use cases.

| Layer                                       | Legacy       | Recommended             |
| ------------------------------------------- | ------------ | --------------------    |
| toolchain: fetch hermetic interpreter       | rules_python | rules_python            |
| deps: fetch and install from pypi           | rules_python | **aspect_rules_py//uv** |
| rules: user-facing implementations          | rules_python | **aspect_rules_py//py** |
| gazelle: generate BUILD files               | rules_python | [`aspect configure`]    |

[`aspect configure`]: https://docs.aspect.build/cli/commands/aspect_configure

## Learn about it

Aspect provides a Bazel training course based on rules_py: [Bazel 102: Python](https://training.aspect.build/bazel-102)

Watch Alex's talk from Monorepo World for a quick demo on how rules_py makes it easy to do Python with Bazel:

[![Python Monorepo World](https://img.youtube.com/vi/en3ep4rw0oA/0.jpg)](https://www.youtube.com/watch?v=en3ep4rw0oA)

_Need help?_ This ruleset has paid support available, see https://aspect.build/services#support

## Differences

We think you'll love rules_py because it fixes many issues with rules_python's rule implementations:

- The launcher uses the Bash toolchain rather than Python, so we have no dependency on a system interpreter. Fixes:
  - [py_binary with hermetic toolchain requires a system interpreter](https://github.com/bazelbuild/rules_python/issues/691)
- We don't mess with the Python `sys.path`/`$PYTHONPATH`. Instead we use the standard `site-packages` folder layout produced by `uv pip install`. This avoids problems like package naming collisions with built-ins (e.g. `collections`) or where `argparse` comes from a transitive dependency instead. Fixes:
  - [Issues with PYTHONPATH resolution in recent python/rules_python versions](https://github.com/bazelbuild/rules_python/issues/1221)
- We run python in isolated mode so we don't accidentally break out of Bazel's action sandbox. Fixes:
  - [pypi libraries installed to system python are implicitly available to builds](https://github.com/bazelbuild/rules_python/issues/27)
  - [sys.path[0] breaks out of runfile tree.](https://github.com/bazelbuild/rules_python/issues/382)
  - [User site-packages directory should be ignored](https://github.com/bazelbuild/rules_python/issues/1059)
- We create a python-idiomatic virtualenv to run actions, which means better compatibility with userland implementations of [importlib](https://docs.python.org/3/library/importlib.html).
- Thanks to the virtualenv, you can open the project in an editor like PyCharm or VSCode and have working auto-complete, jump-to-definition, etc.
  - Fixes [Smooth IDE support for python_rules](https://github.com/bazelbuild/rules_python/issues/1401)

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

In any ancestor `BUILD` file of the Python code, add these lines to instruct [Gazelle] to create `rules_py` variants of the `py_*` rules:

```
# gazelle:map_kind py_library py_library @aspect_rules_py//py:defs.bzl
# gazelle:map_kind py_binary py_binary @aspect_rules_py//py:defs.bzl
# gazelle:map_kind py_test py_test @aspect_rules_py//py:defs.bzl
```

[gazelle]: https://github.com/bazelbuild/rules_python/blob/main/gazelle/README.md

# Public API

See https://registry.bazel.build/docs/aspect_rules_py

# Telemetry & privacy policy

This ruleset collects limited usage data via [`tools_telemetry`](https://github.com/aspect-build/tools_telemetry), which is reported to Aspect Build Inc and governed by our [privacy policy](https://www.aspect.build/privacy-policy).
