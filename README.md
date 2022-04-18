# Aspect's Bazel rules for python

`aspect_rules_py` is a layer on top of `rules_python`, the standard Python ruleset hosted at
https://github.com/bazelbuild/rules_python.
It is currently EXPERIMENTAL and pre-release. No support is promised. There may be breaking changes,
or we may archive and abandon the repository.

Some parts of `rules_python` are reused:

- Same toolchain for fetching a hermetic python interpreter.
- `pip_parse` rule for translating a requirements-lock.txt file into Bazel repository fetching rules
  and installing those packages into external repositories.
- The Gazelle extension for generating BUILD.bazel files works the same.

However, this ruleset introduces a new implementation of `py_library`, `py_binary`, and `py_test`.
The starlark implementations allow us to innovate, while the existing ones are embedded in Bazel's
Java sources in the bazelbuild/bazel repo and therefore very difficult to get changes made.

> We understand that there is also an effort at Google to "starlarkify" the Python rules,
> but there is no committed roadmap or dates.
> Given the history of other projects coming from Google, we've chosen not to wait.

Our philosophy is to behave more like idiomatic python ecosystem tools.
Having a starlark implementation allows us to do things like
attach Bazel transitions, mypy typechecking actions, etc.

Things that are improved in rules_py:

- We don't mess with the Python `sys.path`/`$PYTHONPATH`. Instead we use the standard `site-packages` folder layout produced by `pip_install`. This avoids problems like package naming collisions with built-ins (e.g. `collections`) or where `argparse` comes from a transitive dependency instead. (Maybe helps with diamond dependencies too).
- We run python in isolated mode so we don't accidentally break out of Bazel's action sandbox, fixing:
  - [pypi libraries installed to system python are implicitly available to builds](https://github.com/bazelbuild/rules_python/issues/27)
  - [sys.path[0] breaks out of runfile tree.](https://github.com/bazelbuild/rules_python/issues/382)
- We create a python-idiomatic virtualenv to run actions, which means better compatibility with userland implementations of [importlib](https://docs.python.org/3/library/importlib.html).
- Thanks to the virtualenv, you can open the project in an editor like PyCharm and have working auto-complete, jump-to-definition, etc.
- The launcher uses the Bash toolchain rather than Python, so we have no dependency on a system interpreter - fixes MacOS no longer shipping with python.

Improvements planned:

- Build wheels in actions, so it's possible to have native packages built for the target platform,
  e.g. for a rules_docker py3_image.
- Support `--only_binary=:all:` by always building wheels from source using a hermetic Bazel cc toolchain.
- `dep` on wheels directly, rather than on a `py_library` that wraps it. Then we don't have to append to the `.pth` file to locate them.

## Installation

From the release you wish to use:
<https://github.com/aspect-build/rules_py/releases>
copy the WORKSPACE snippet into your `WORKSPACE` file.
