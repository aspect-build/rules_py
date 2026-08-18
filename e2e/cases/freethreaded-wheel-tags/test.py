"""Basic hypothesis usage on a free-threaded (3.14t) interpreter."""

import sys
import sysconfig
import unittest

from hypothesis import given, settings, strategies as st


class HypothesisFreethreadedTest(unittest.TestCase):
    def test_interpreter_is_freethreaded_314(self) -> None:
        self.assertEqual(sys.version_info[:2], (3, 14), sys.version)
        gil_disabled = sysconfig.get_config_var("Py_GIL_DISABLED")
        self.assertEqual(gil_disabled, 1, "Expected Py_GIL_DISABLED=1 for a freethreaded build")

    def test_hypothesis_import(self) -> None:
        import hypothesis

        self.assertTrue(hypothesis.__version__)

    @given(st.integers(), st.integers())
    @settings(max_examples=50)
    def test_given_integers(self, a: int, b: int) -> None:
        self.assertEqual(a + b, b + a)

    @given(st.lists(st.text()))
    @settings(max_examples=50)
    def test_given_text_lists(self, items: list[str]) -> None:
        self.assertEqual(sorted(sorted(items)), sorted(items))


if __name__ == "__main__":
    unittest.main()
