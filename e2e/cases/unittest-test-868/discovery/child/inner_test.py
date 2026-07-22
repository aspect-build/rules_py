import unittest


class InnerTest(unittest.TestCase):
    def test_inner(self) -> None:
        # Nested under a sibling root of outer_test.py. Directory-based
        # discovery would collect (and run) this twice; file-based loading
        # runs it exactly once.
        self.assertTrue(True)
