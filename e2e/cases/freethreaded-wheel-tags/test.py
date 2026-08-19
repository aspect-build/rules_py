"""Basic hypothesis usage on a free-threaded (3.14t) interpreter."""

import os
import sys
import sysconfig
import unittest

from hypothesis import given, settings, strategies as st

EXPECTED_VERSION = tuple(int(p) for p in os.environ.get("EXPECTED_PY_VERSION", "3.14").split("."))


class HypothesisFreethreadedTest(unittest.TestCase):
    def test_interpreter_is_freethreaded(self) -> None:
        self.assertEqual(sys.version_info[:2], EXPECTED_VERSION, sys.version)
        gil_disabled = sysconfig.get_config_var("Py_GIL_DISABLED")
        self.assertEqual(gil_disabled, 1, "Expected Py_GIL_DISABLED=1 for a freethreaded build")

    def test_hypothesis_import(self) -> None:
        import hypothesis

        self.assertTrue(hypothesis.__version__)

    def test_native_extension_abi(self) -> None:
        from hypothesis import _native

        # 3.15+ freethreaded must select the compound cp315-abi3.abi3t wheel,
        # whose extension uses the PEP 803 .abi3t suffix.
        if EXPECTED_VERSION >= (3, 15) and not sys.platform.startswith("win"):
            self.assertIn(".abi3t", _native.__file__, _native.__file__)

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
