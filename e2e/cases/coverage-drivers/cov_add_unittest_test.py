import unittest

from foo import add, subtract


class AddTest(unittest.TestCase):
    def test_add(self) -> None:
        self.assertEqual(add(1, 2), 3)

    def test_subtract(self) -> None:
        self.assertEqual(subtract(5, 2), 3)


if __name__ == "__main__":
    unittest.main()
