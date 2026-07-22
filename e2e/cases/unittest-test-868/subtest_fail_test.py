import unittest


class SubTestFail(unittest.TestCase):
    def test_with_subtests(self) -> None:
        # i == 1 fails; the others pass. unittest reports the run as failed via
        # the exit code either way, but without the driver's addSubTest -> XML
        # recording the JUnit output would claim zero failures.
        for i in range(3):
            with self.subTest(i=i):
                self.assertNotEqual(i, 1)


if __name__ == "__main__":
    unittest.main()
