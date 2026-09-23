import unittest

import firstparty.greet


class ManifestTest(unittest.TestCase):
    def test_greet(self) -> None:
        self.assertIn("first-party", firstparty.greet.GREETING)
