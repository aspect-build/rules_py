"""
Normalize a PyPI package name to allow consistent label names

Note we chose `_` instead of `-` as a separator as there are certain
requirements around Bazel labels that we need to consider.

From the Bazel docs:
> Package names must be composed entirely of characters drawn from the set
> A-Z, a–z, 0–9, '/', '-', '.', and '_', and cannot start with a slash.

However, due to restrictions on Bazel labels we also cannot allow hyphens.
See https://github.com/bazelbuild/bazel/issues/6841

Further, some Python rulesets automatically add the repository root to the
PYTHONPATH, meaning a package that has the same name as a module is picked
up. We workaround this by prefixing with `<hub_name>_`.

Alternatively we could require
`--noexperimental_python_import_all_repositories` be set, however this
breaks rules_docker.
See: https://github.com/bazelbuild/bazel/issues/2636

Also see Python spec on normalizing package names:
https://packaging.python.org/en/latest/specifications/name-normalization/
"""

def normalize_name(name):
    """normalize a PyPI package name and return a valid bazel label.

    Args:
        name: str, the PyPI package name.

    Returns:
        a normalized name as a string.
    """
    name = name.replace("-", "_").replace(".", "_").lower()
    if "__" not in name:
        return name

    return "_".join([
        part
        for part in name.split("_")
        if part
    ])
