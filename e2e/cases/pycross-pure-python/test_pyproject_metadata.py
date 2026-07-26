import unittest

import pyproject_metadata


class TestPyprojectMetadata(unittest.TestCase):
    def test_import(self):
        self.assertIsNotNone(pyproject_metadata.__version__)


if __name__ == "__main__":
    unittest.main()
