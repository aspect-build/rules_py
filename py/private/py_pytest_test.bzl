# `py_pytest_test` is a purpose-oriented test macro that always drives the
# suite with pytest. It owns everything the pytest driver needs so that the
# generic `py_test` never has to know about pytest:
#
#   * shared pytest entrypoint injection (no per-test codegen in the common
#     case; reuses //py/private:pytest_main.py + :default_pytest_main),
#   * `pytest_paths` discovery-root computation,
#   * per-test entrypoint codegen (via py_pytest_main) only when baked
#     `pytest_args`/`chdir` are requested,
#   * pytest-dependency validation.

"""Pytest-driving test macro and the driver wiring it shares with py_test.

## Test module naming under Bazel packages

pytest names a test module by walking up from the file while each directory has
an `__init__.py`. Bazel packages routinely have none, so the walk stops early and
the module is imported -- and registered in `sys.modules` -- under a truncated
name: a test in `mypkg/azure/` becomes `azure.foo_test`, binding
`sys.modules["azure"]` to the first-party package.

When a package directory shares its name with an installed distribution, that
distribution is then shadowed for the code under test, and `from azure.storage
import ...` raises `ModuleNotFoundError` under Bazel while the same code is
correct under pip. The symptom points nowhere near module naming, so it is worth
knowing before you meet it.

pytest 8.1's `consider_namespace_packages` makes it name the module by its full
path instead. Set it per target, either way round:

```starlark
py_pytest_test(
    name = "my_test",
    srcs = ["my_test.py"],
    env = {"PYTEST_ADDOPTS": "-o consider_namespace_packages=true"},
)
```

Directory names have to be valid Python identifiers for this: a test under
`my-pkg/` becomes `my-pkg.foo_test`, which collection tolerates but
`pkgutil.resolve_name` -- and so pytest-mock's `mocker.patch` -- rejects. That is
why it is opt-in per target rather than on by default.
"""

load("//py/private:py_pytest_main.bzl", "py_pytest_main", "pytest_paths", "wrapped_main_filename")
load(
    "//py/private/py_venv:defs.bzl",
    "py_binary_with_venv",
    "py_venv_exec_test",
)

def pytest_driver_wiring(name, srcs, deps, kwargs, pytest_args = [], chdir = None):
    """Inject the pytest driver into a to-be-created test target.

    Mutates `deps` and `kwargs` in place (adds the pytest entrypoint dep and
    the `.pytest_paths` data file) and returns the `main` label the caller
    should hand to the underlying test rule.

    Args:
        name: the test target name.
        srcs: the test sources; pytest collects exactly these files.
        deps: the test deps list, appended to in place.
        kwargs: the forwarded kwargs dict; `data` is read/rewritten in place.
        pytest_args: args baked into a per-test entrypoint. When empty, the
            prebuilt shared main is reused with zero codegen.
        chdir: optional dir to chdir into before pytest starts; forces codegen.

    Returns:
        The `main` label for the underlying test rule.
    """
    tags = kwargs.get("tags", [])

    if pytest_args or chdir:
        # Baked args/chdir must be rendered into a private entrypoint. Delegate
        # to py_pytest_main, which dunder-wraps the generated file (#723) so
        # pytest won't collect it as a test module.
        main_target = name + "_pytest_main"

        # py_pytest_main already injects the pytest_shard dep into its library.
        py_pytest_main(
            name = main_target,
            args = pytest_args,
            chdir = chdir,
            tags = tags,
        )
        deps.append(":" + main_target)

        # Point at py_pytest_main's generated entrypoint (same wrapping,
        # slash-name-safe).
        main = ":" + wrapped_main_filename(main_target)
    else:
        # Common path: reuse the prebuilt shared main. No per-test codegen.
        main = Label("//py/private:pytest_main.py")
        deps.append(Label("//py/private:default_pytest_main"))

    # Write the test srcs to a runfile the shared main reads at startup and
    # passes to pytest, so pytest collects only from this target's own sources
    # rather than autodiscovering from the runfiles root.
    paths_target = name + ".pytest_paths"
    pytest_paths(
        name = paths_target,
        srcs = srcs,
        testonly = True,
        tags = tags,
    )
    data = list(kwargs.pop("data", []))
    data.append(paths_target)
    kwargs["data"] = data

    return main

def py_pytest_test(
        name,
        srcs = [],
        deps = [],
        pytest_args = [],
        chdir = None,
        resolutions = None,
        **kwargs):
    """A `py_test` that always runs under pytest.

    Pytest is always the driver, so the entrypoint wiring is unambiguous.
    Include the `pytest` package (and `coverage`, if you want coverage) in
    `deps`.

    Every file in `srcs` is a test module that pytest collects (scoped to the
    target, not the whole runfiles tree). Put importable support code in `deps`
    and pytest's `conftest.py` in `data`; to select tests by name pattern, use
    Bazel's `glob()` in the `srcs` list.

    If a package directory here shares its name with a distribution in `deps`,
    see the module docs above: pytest may name test modules by a truncated path
    and shadow that distribution for the code under test. `consider_namespace_packages`
    (pytest 8.1+), via `env` or `pytest_args`, is the fix.

    Args:
        name: Name of the rule.
        srcs: Python test source files; pytest collects exactly these.
        deps: Dependencies; must include the pytest package
            (e.g. `@pypi_pytest//:pkg`).
        pytest_args: Extra arguments baked into the pytest invocation. Setting
            this renders a private per-test entrypoint instead of reusing the
            shared main.
        chdir: Optional directory to change into before pytest runs, relative
            to the runfiles root. Also forces a private per-test entrypoint.
        resolutions: virtual-dep resolutions, a dict of virtual dependency
            name to the label of an installed package providing it.
        **kwargs: forwarded to the underlying test rule and sibling py_venv.
    """
    if "main" in kwargs:
        fail("py_pytest_test provides its own entrypoint; `main` is not supported. Use py_pytest_main + py_test for a custom main.")

    kwargs["testonly"] = True

    deps = list(deps)
    main = pytest_driver_wiring(
        name = name,
        srcs = srcs,
        deps = deps,
        kwargs = kwargs,
        pytest_args = pytest_args,
        chdir = chdir,
    )

    py_binary_with_venv(
        py_venv_exec_test,
        name = name,
        srcs = srcs,
        deps = deps,
        main = main,
        resolutions = resolutions,
        **kwargs
    )
