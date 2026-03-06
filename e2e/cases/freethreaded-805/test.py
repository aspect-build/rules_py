"""Test that a freethreaded interpreter can import native extensions built for the 't' ABI."""

import os
import sys
import sysconfig
import unittest


class FreethreadedTest(unittest.TestCase):
    def test_interpreter_is_freethreaded(self):
        """The interpreter must be a free-threaded build (no GIL)."""
        gil_disabled = sysconfig.get_config_var("Py_GIL_DISABLED")
        self.assertEqual(gil_disabled, 1, "Expected Py_GIL_DISABLED=1 for a freethreaded build")

    def test_abi_tag_contains_t(self):
        """The SOABI should contain 't' indicating the freethreaded ABI."""
        soabi = sysconfig.get_config_var("SOABI") or ""
        # Freethreaded SOABI looks like "cpython-313t-x86_64-linux-gnu"
        self.assertRegex(soabi, r"cpython-\d+t", f"Expected freethreaded SOABI, got: {soabi!r}")

    def test_regex_import_and_use(self):
        """regex must be importable and functional."""
        import regex

        m = regex.match(r"(\w+)\s(\w+)", "Hello World")
        self.assertIsNotNone(m)
        self.assertEqual(m.group(1), "Hello")
        self.assertEqual(m.group(2), "World")

    def test_regex_native_extension_is_freethreaded(self):
        """The regex C extension .so must be the freethreaded variant."""
        import regex
        # Find the _regex native extension within regex's package directory
        regex_dir = os.path.dirname(regex.__file__)
        so_files = [f for f in os.listdir(regex_dir) if f.startswith("_regex") and ".so" in f]
        self.assertTrue(so_files, f"No _regex .so found in {regex_dir}")
        # The .so filename should contain the 't' ABI flag, e.g. _regex.cpython-313t-...
        so_name = so_files[0]
        self.assertRegex(so_name, r"cpython-3\d+t", f"Expected freethreaded .so, got: {so_name}")


if __name__ == "__main__":
    unittest.main()
