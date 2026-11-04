"""Every first-party module loads from bytecode under sourceless."""

import unittest

import formatting
import greeting
import styling
import version


class BatchedBytecodeTest(unittest.TestCase):
    def test_modules_are_sourceless(self) -> None:
        for module in (formatting, greeting, styling, version):
            self.assertTrue(module.__file__.endswith(".pyc"), module.__file__)

    def test_greeting(self) -> None:
        self.assertEqual(greeting.greet("bazel"), "*** Hello, BAZEL! (v1.0) ***")


if __name__ == "__main__":
    unittest.main()
