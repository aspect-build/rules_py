import unittest

import filelock


class TestFileLock(unittest.TestCase):
    def test_import(self) -> None:
        lock = filelock.FileLock("dummy.lock")
        self.assertIsNotNone(lock)


if __name__ == "__main__":
    unittest.main()
