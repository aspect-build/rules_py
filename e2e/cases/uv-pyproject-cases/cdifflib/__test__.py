"""Smoke test: cdifflib 1.2.9 built from sdist imports and behaves like
difflib. The real assertion this case carries is that the sdist build
itself succeeded — without `--skip-dependency-check` on `python -m
build`, the build rejects cdifflib because its `[build-system].requires`
lists pytest / ruff / twine, none of which are in the build venv.

The version pin is load-bearing: the bug shape (unusual
`[build-system].requires`) is specific to cdifflib 1.2.9. Assert
explicitly so a stale lockfile or relaxed constraint that resolves
to a different release doesn't silently turn this into a no-op.
"""

from importlib.metadata import version

import cdifflib

assert version("cdifflib") == "1.2.9", (
    "this case is pinned to cdifflib 1.2.9 — the `[build-system].requires` "
    "shape it covers is version-specific; re-verify the bug reproduces "
    "before re-pinning"
)

a = ["one\n", "two\n", "three\n"]
b = ["one\n", "two_modified\n", "three\n"]

differ = cdifflib.CSequenceMatcher(a=a, b=b)
ratio = differ.ratio()
assert 0 < ratio < 1, ratio

print("cdifflib imported from sdist: OK (ratio={:.3f})".format(ratio))
