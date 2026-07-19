import unittest


class SameNameATest(unittest.TestCase):
    def test_from_a(self) -> None:
        # Same basename as b/same_test.py. discover() imports both by basename
        # and raises ImportError; the path-derived module name keeps them
        # distinct.
        self.assertTrue(True)
