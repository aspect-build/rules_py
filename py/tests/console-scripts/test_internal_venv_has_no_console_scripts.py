import os
import sys
import unittest


class InternalVenvTest(unittest.TestCase):
    def test_bin_contains_no_console_script_wrappers(self) -> None:
        bin_dir = os.path.dirname(sys.executable)
        entries = os.listdir(bin_dir)
        self.assertNotIn("activate", entries)
        for name in entries:
            self.assertTrue(name.startswith("python"), name)
            self.assertTrue(os.path.islink(os.path.join(bin_dir, name)), name)


if __name__ == "__main__":
    sys.exit(unittest.main())
