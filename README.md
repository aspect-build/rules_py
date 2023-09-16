# Aspect's Bazel rules for python

`aspect_rules_py` is a layer on top of `rules_python`, the standard Python ruleset hosted at
https://github.com/bazelbuild/rules_python.
It is currently in pre-release, but we are committed to more development towards a 1.0 stable release.

The lower layer of `rules_python` is currently reused, dealing with the toolchain and dependencies:

- Same toolchain for fetching a hermetic python interpreter.
- `pip_parse` rule for translating a requirements-lock.txt file into Bazel repository fetching rules
  and installing those packages into external repositories.
- The Gazelle extension for generating BUILD.bazel files works the same.

However, this ruleset introduces a new implementation of `py_library`, `py_binary`, and `py_test`.
Our philosophy is to behave more like idiomatic python ecosystem tools, where rules_python is closely
tied to the way Google does Python development in their internal monorepo, google3.

Things you'll love about rules_py:

- We don't mess with the Python `sys.path`/`$PYTHONPATH`. Instead we use the standard `site-packages` folder layout produced by `pip_install`. This avoids problems like package naming collisions with built-ins (e.g. `collections`) or where `argparse` comes from a transitive dependency instead.
- We run python in isolated mode so we don't accidentally break out of Bazel's action sandbox, fixing bugs like:
  - [pypi libraries installed to system python are implicitly available to builds](https://github.com/bazelbuild/rules_python/issues/27)
  - [sys.path[0] breaks out of runfile tree.](https://github.com/bazelbuild/rules_python/issues/382)
- We create a python-idiomatic virtualenv to run actions, which means better compatibility with userland implementations of [importlib](https://docs.python.org/3/library/importlib.html).
- Thanks to the virtualenv, you can open the project in an editor like PyCharm and have working auto-complete, jump-to-definition, etc.
- The launcher uses the Bash toolchain rather than Python, so we have no dependency on a system interpreter.

_Need help?_ This ruleset has support provided by https://aspect.dev.

## Installation

Follow instructions from the release you wish to use:
<https://github.com/aspect-build/rules_py/releases>
