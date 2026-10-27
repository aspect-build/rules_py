import sys
import unittest


class NonDefaultVersionTest(unittest.TestCase):
    def test_runs_requested_version(self) -> None:
        self.assertEqual(sys.version_info[:2], (3, 12))


if __name__ == "__main__":
    unittest.main()
