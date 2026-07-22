import unittest


class ExternalRepoTest(unittest.TestCase):
    def test_external_source_is_collected(self) -> None:
        # Lives in an external repo (short_path ../test_driver_extrepo/...). If
        # the driver dropped it, the target would report "no tests found".
        self.assertTrue(True)


if __name__ == "__main__":
    unittest.main()
