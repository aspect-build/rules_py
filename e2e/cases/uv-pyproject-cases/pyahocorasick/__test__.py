"""Smoke test for pyahocorasick 2.2.0 built from sdist via pep517_whl.

If the wheel built and installed, the C extension is loadable and the
Automaton API works end-to-end — that's all this case needs to verify.
"""

import ahocorasick


def test_search():
    automaton = ahocorasick.Automaton()
    for idx, word in enumerate(("he", "her", "his", "she")):
        automaton.add_word(word, (idx, word))
    automaton.make_automaton()

    found = sorted(word for _, (_, word) in automaton.iter("ushers"))
    assert found == ["he", "her", "she"], found


if __name__ == "__main__":
    test_search()
    print("OK")
