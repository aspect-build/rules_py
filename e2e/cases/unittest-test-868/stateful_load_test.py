import unittest
from typing import Optional

# Counts load_tests invocations across the process. The driver must collect the
# suite exactly once; a second loadTestsFromModule pass (the old double-collect
# bug) would hand the runner the empty suite returned below and silently "Ran 0
# tests" while still exiting 0.
_calls = []


class StatefulLoadTest(unittest.TestCase):
    def test_runs_once(self) -> None:
        self.assertTrue(True)


def load_tests(
    loader: unittest.TestLoader,
    tests: unittest.TestSuite,
    pattern: Optional[str],
) -> unittest.TestSuite:
    _calls.append(1)
    if len(_calls) > 1:
        return unittest.TestSuite()
    return loader.loadTestsFromTestCase(StatefulLoadTest)
