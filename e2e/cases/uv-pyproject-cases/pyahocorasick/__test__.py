"""Smoke test: pyahocorasick 2.2.0 built from sdist exposes a working
`ahocorasick.Automaton`. The real assertion this case carries is that
the C extension built at all — see the BUILD.bazel comment for the
specific tmp_root / compiler-wrapper plumbing this exercises.

The version pin is load-bearing: the bug shape (setup.py + setup.cfg,
no pyproject.toml) is what makes this case cover the native-build
path through `build_helper.py`. Assert explicitly so a future
pyahocorasick release that adds a pyproject.toml doesn't silently
flip this case to a different code path.
"""

from importlib.metadata import version

import ahocorasick

assert version("pyahocorasick") == "2.2.0", (
    "this case is pinned to pyahocorasick 2.2.0 — the sdist shape it "
    "covers (setup.py + setup.cfg, no pyproject.toml) is version-specific; "
    "re-verify the bug reproduces before re-pinning"
)

a = ahocorasick.Automaton()
for idx, key in enumerate(["he", "she", "his", "hers"]):
    a.add_word(key, (idx, key))
a.make_automaton()

hits = [value for _, value in a.iter("ushers")]
assert hits, hits
assert ("she" in {key for _, key in hits}), hits

print("pyahocorasick imported from sdist: OK (hits={})".format(hits))
