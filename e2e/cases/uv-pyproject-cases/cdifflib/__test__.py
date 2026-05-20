"""Smoke test that cdifflib built from sdist imports and works.

The version assertion below is load-bearing — see this case's
BUILD.bazel for why the pin matters.
"""

from importlib.metadata import version

import cdifflib

assert version("cdifflib") == "1.2.9", (
    "cdifflib version drift — see cases/uv-pyproject-cases/cdifflib/BUILD.bazel"
)

a = ["one\n", "two\n", "three\n"]
b = ["one\n", "two_modified\n", "three\n"]

differ = cdifflib.CSequenceMatcher(a=a, b=b)
ratio = differ.ratio()
assert 0 < ratio < 1, ratio

print("cdifflib imported from sdist: OK (ratio={:.3f})".format(ratio))
