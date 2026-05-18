"""Smoke test: pyahocorasick 2.2.0 built from sdist exposes a working
`ahocorasick.Automaton`. The real assertion this case carries is that
the C extension built at all — the compiler subprocess depends on
TMP / TEMP / TEMPDIR being valid from its own cwd inside the worktree,
which only holds once tmp_root is an absolute path.
"""

import ahocorasick

a = ahocorasick.Automaton()
for idx, key in enumerate(["he", "she", "his", "hers"]):
    a.add_word(key, (idx, key))
a.make_automaton()

hits = [value for _, value in a.iter("ushers")]
assert hits, hits
assert ("she" in {key for _, key in hits}), hits

print("pyahocorasick imported from sdist: OK (hits={})".format(hits))
