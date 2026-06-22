"""Imports group-b's packages: the shared cowsay plus its exclusive wcwidth.

Run from a py_test with deps = group_deps() under dep_group
requirements-bzl-group-b. cowsay also lives in requirements-bzl-demo, so this
proves a shared package appears in both groups' lists; wcwidth is exclusive
to group-b. If demo's exclusive packages (python-dateutil, six) leaked into
group-b's list they would be incompatible under this dep_group and analysis
would fail."""

import cowsay
import wcwidth

assert hasattr(cowsay, "cow")
assert hasattr(wcwidth, "wcwidth")
print("group-b hub: cowsay (shared) + wcwidth (exclusive) importable via per-group list")
