import unittest


class ExampleTest(unittest.TestCase):
    def test_addition(self) -> None:
        self.assertEqual(1 + 1, 2)

    def test_string(self) -> None:
        self.assertIn("ell", "hello")


if __name__ == "__main__":
    unittest.main()
