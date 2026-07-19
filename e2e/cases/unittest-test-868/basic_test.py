import unittest


class BasicTest(unittest.TestCase):
    def test_pass(self) -> None:
        self.assertEqual(2 + 2, 4)

    def test_membership(self) -> None:
        self.assertIn("ell", "hello")

    @unittest.skip("exercises the <skipped> element in the JUnit writer")
    def test_skipped(self) -> None:
        self.fail("should never run")


if __name__ == "__main__":
    unittest.main()
