"""Smoke test that pyahocorasick built from sdist imports and the
`ahocorasick.Automaton` C extension works.

The version assertion below is load-bearing — see this case's
BUILD.bazel for why the pin matters.
"""

from importlib.metadata import version

import ahocorasick

assert version("pyahocorasick") == "2.2.0", (
    "pyahocorasick version drift — see cases/uv-pyproject-cases/pyahocorasick/BUILD.bazel"
)

a = ahocorasick.Automaton()
for idx, key in enumerate(["he", "she", "his", "hers"]):
    a.add_word(key, (idx, key))
a.make_automaton()

hits = [value for _, value in a.iter("ushers")]
assert hits, hits
assert ("she" in {key for _, key in hits}), hits

print("pyahocorasick imported from sdist: OK (hits={})".format(hits))
