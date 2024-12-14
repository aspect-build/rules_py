"""Use pytest to run tests, using a wrapper script to interface with Bazel.

Example:

```starlark
load("@aspect_rules_py//pytest:defs.bzl", "py_pytest_test")

py_pytest_test(
    name = "test_w_pytest",
    size = "small",
    srcs = ["test.py"],
)
```

By default, `@pip//pytest` is added to `deps`.
If sharding is used (when `shard_count > 1`) then `@pip//pytest_shard` is also added.
To instead provide explicit deps for the pytest library, set `pytest_deps`:

```starlark
py_pytest_test(
    name = "test_w_my_pytest",
    shard_count = 2,
    srcs = ["test.py"],
    pytest_deps = [requirement("pytest"), requirement("pytest-shard"), ...],
)
```
"""

load("//py:defs.bzl", "py_test")

def py_pytest_test(name, srcs, deps = [], args = [], pytest_deps = None, pip_repo = "pip", **kwargs):
    """
    Wrapper macro for `py_test` which supports pytest.

    Args:
      name: A unique name for this target.
      srcs: Python source files.
      deps: Dependencies, typically `py_library`.
      args: Additional command-line arguments to pytest.
        See https://docs.pytest.org/en/latest/how-to/usage.html
      pytest_deps: Labels of the pytest tool and other packages it may import.
      pip_repo: Name of the external repository where Python packages are installed.
        It's typically created by `pip.parse`.
        This attribute is used only when `pytest_deps` is unset.
      **kwargs: Additional named parameters to py_test.
    """
    shim_label = Label("//pytest:pytest_shim.py")

    if pytest_deps == None:
        pytest_deps = ["@{}//pytest".format(pip_repo)]
        if kwargs.get("shard_count", 1) > 1:
            pytest_deps.append("@{}//pytest_shard".format(pip_repo))

    py_test(
        name = name,
        srcs = [
            shim_label,
        ] + srcs,
        main = shim_label,
        args = [
            "--capture=no",
        ] + args + ["$(location :%s)" % x for x in srcs],
        deps = deps + pytest_deps,
        **kwargs
    )
