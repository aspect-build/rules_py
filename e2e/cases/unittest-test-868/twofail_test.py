import unittest


class TwoFailTest(unittest.TestCase):
    # Two independently failing methods, ordered by name so fail-fast stops
    # after the first. Fails by design; driven manually by check_failfast.sh.
    def test_a_first(self) -> None:
        self.fail("first failure")

    def test_b_second(self) -> None:
        self.fail("second failure")
