"""Ordinary Python must get tornado's cp39-abi3 wheel; free-threaded Python
must not, since stable-ABI extensions crash or re-enable the GIL there."""

import importlib.metadata
import os
import sys
import sysconfig
import unittest


class Abi3FreethreadedTest(unittest.TestCase):
    freethreaded = os.environ.get("EXPECT_FREETHREADED") == "1"

    def wheel_tags(self) -> list[str]:
        wheel = importlib.metadata.distribution("tornado").read_text("WHEEL")
        assert wheel is not None
        return [line.split(":", 1)[1].strip() for line in wheel.splitlines() if line.startswith("Tag:")]

    def test_interpreter(self) -> None:
        self.assertEqual(sys.version_info[:2], (3, 14), sys.version)
        self.assertEqual(bool(sysconfig.get_config_var("Py_GIL_DISABLED")), self.freethreaded)

    def test_wheel_selection(self) -> None:
        tags = self.wheel_tags()
        if self.freethreaded:
            self.assertFalse(any("-abi3-" in t for t in tags), tags)
            self.assertTrue(any(t.startswith("cp314-cp314t-") for t in tags), tags)
        else:
            self.assertTrue(any(t.startswith("cp39-abi3-") for t in tags), tags)

    def test_native_extension(self) -> None:
        import tornado.speedups

        self.assertTrue(tornado.speedups.__file__)
        if self.freethreaded:
            self.assertFalse(sys._is_gil_enabled())


if __name__ == "__main__":
    unittest.main()
