import unittest

import tomli


class TestTomli(unittest.TestCase):
    def test_parse(self):
        d = tomli.loads("a = 1")
        self.assertEqual(d["a"], 1)


if __name__ == "__main__":
    unittest.main()
