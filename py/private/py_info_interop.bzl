"""Interop between rules_py's `PyInfo` and `@rules_python`'s.

The `deps` attribute shared by py_library/py_binary/py_test (and rules reusing
their attrs) accepts targets built by either ruleset. rules_py always emits its
own `PyInfo` (`//py/private:py_info.bzl`); native `@rules_python` targets (e.g.
a `py_proto_library`) carry `@rules_python`'s. Both expose `transitive_sources`
and `imports`, which is everything rules_py reads from a foreign dep.

This module is the single place that knows about both providers. Rule code
calls these accessors at the API edge instead of loading `@rules_python`'s
provider directly, so a field read added for one provider cannot silently miss
the other. rules_py never *emits* `@rules_python`'s provider — the reverse
direction (a `@rules_python` rule consuming a rules_py target) is not supported.
"""

load("@rules_python//python:defs.bzl", _RulesPythonPyInfo = "PyInfo")
load("//py/private:py_info.bzl", "PyInfo")

# Re-exported for `providers` constraints on `deps`-style attributes.
RulesPythonPyInfo = _RulesPythonPyInfo

def has_py_info(target):
    """Whether the target carries rules_py's or `@rules_python`'s `PyInfo`."""
    return PyInfo in target or RulesPythonPyInfo in target

def get_py_info(target):
    """Return the target's `PyInfo` — rules_py's if present, else `@rules_python`'s, else `None`."""
    if PyInfo in target:
        return target[PyInfo]
    if RulesPythonPyInfo in target:
        return target[RulesPythonPyInfo]
    return None
