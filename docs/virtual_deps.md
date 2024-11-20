# Resolution of "virtual" dependencies

rules_py allows external Python dependencies to be specified by name rather than as a label to an installed package, using a concept called "virtual" dependencies. 

Virtual dependencies allow the terminal rule (for example, a `py_binary` or `py_test`) to control the version of the package which is used to satisfy the dependency, by providing a mapping from the package name to the label of an installed package that provides it.

This feature allows:
- for individual projects within a monorepo to upgrade their dependencies independently of other projects within the same repository
- overriding a single version of a dependency for a py_binary or py_test
- to test against a range of different versions of dependencies for a single library

Links to design docs are available on the original feature request:
https://github.com/aspect-build/rules_py/issues/213

## Declaring a dependency as virtual

Simply move an element from the `deps` attribute to `virtual_deps`.

For example, instead of getting a specific version of Django from
`deps = ["@pypi_django//:pkg"]` on a `py_library` target,
provide the package name with `virtual_deps = ["django"]`.

> Note that any `py_binary` or `py_test` transitively depending on this `py_library` must be loaded from `aspect_rules_py` rather than `rules_python`, as the latter does not have a feature of resolving the virtual dep.

## Resolving to a package installed by rules_python

Typically, users write one or more `pip_parse` statements in `WORKSPACE` or `pip.parse` in `MODULE.bazel` to read requirements files, and install the referenced packages into an external repository. For example, from the [rules_python docs](https://rules-python.readthedocs.io/en/latest/pypi-dependencies.html#using-dependencies-from-pypi):

```
pip = use_extension("@rules_python//python/extensions:pip.bzl", "pip")
pip.parse(
    hub_name = "my_deps",
    python_version = "3.11",
    requirements_lock = "//:requirements_lock_3_11.txt",
)
use_repo(pip, "my_deps")
```

rules_python writes a `requirements.bzl` file which provides some symbols to work with the installed packages:

```
load("@my_deps//:requirements.bzl", "all_whl_requirements_by_package", "requirement")
```

These can be used to resolve a virtual dependency. Continuing the Django example above, a binary rule can specify which external repository to resolve to:

```
load("@aspect_rules_py//py:defs.bzl", "resolutions")

py_binary(
    name = "manage",
    srcs = ["manage.py"],
    # Resolve django to the "standard" one from our requirements.txt
    resolutions = resolutions.from_requirements(all_whl_requirements_by_package, requirement),
)
```

## Resolving directly to a binary wheel

It's possible to fetch a wheel file directly without using `pip` or any repository rules from `rules_python`, using the Bazel downloader.

`MODULE.bazel`:

```
http_file = use_repo_rule("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")

http_file(
    name = "django_4_2_4",
    urls = ["https://files.pythonhosted.org/packages/7f/9e/fc6bab255ae10bc57fa2f65646eace3d5405fbb7f5678b90140052d1db0f/Django-4.2.4-py3-none-any.whl"],
    sha256 = "860ae6a138a238fc4f22c99b52f3ead982bb4b1aad8c0122bcd8c8a3a02e409d",
    downloaded_file_path = "Django-4.2.4-py3-none-any.whl",
)
```

Then in a `BUILD` file, extract it to a directory:

```
load("@aspect_rules_py//py:defs.bzl", "py_binary", "py_unpacked_wheel")

# Extract the downloaded wheel to a directory
py_unpacked_wheel(
    name = "django_4_2_4",
    src = "@django_4_2_4//file",
)

py_binary(
    name = "manage.override_django",
    srcs = ["proj/manage.py"],
    resolutions = {
        # replace the resolution of django with that specific wheel
        "django": ":django_4_2_4",
    },
    deps = [":proj"],
)
```

