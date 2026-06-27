"""Smoke test that cowsay was resolved via the chosen hub label shape."""

import cowsay


def test_cowsay_imports():
    # cowsay's get_output_string is a stable API; reaching it confirms the
    # whl was actually unpacked into the venv.
    assert cowsay.get_output_string("cow", "moo")
