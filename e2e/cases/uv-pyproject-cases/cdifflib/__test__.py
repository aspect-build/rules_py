"""Smoke test: cdifflib 1.2.9 built from sdist imports and behaves like
difflib. The real assertion this case carries is that the sdist build
itself succeeded — without the "prefer setup.py when pyproject metadata
is incomplete" PEP 517 fallback, `python -m build --no-isolation`
rejects cdifflib because its `[build-system].requires` lists pytest /
ruff / twine, none of which are in the build venv.
"""

import cdifflib

a = ["one\n", "two\n", "three\n"]
b = ["one\n", "two_modified\n", "three\n"]

differ = cdifflib.CSequenceMatcher(a=a, b=b)
ratio = differ.ratio()
assert 0 < ratio < 1, ratio

print("cdifflib imported from sdist: OK (ratio={:.3f})".format(ratio))
