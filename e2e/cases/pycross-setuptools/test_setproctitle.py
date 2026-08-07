import unittest

import setproctitle


class TestSetproctitle(unittest.TestCase):
    def test_import(self) -> None:
        title = setproctitle.getproctitle()
        self.assertIsNotNone(title)


if __name__ == "__main__":
    unittest.main()
