"""Tests for the --expect-version guard in pyc_compile.py."""

import os
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.environ["PYC_COMPILE"]

_PRERELEASE_ABBREVS = {"alpha": "a", "beta": "b", "candidate": "rc"}


def running_version():
    version = "{}.{}.{}".format(*sys.version_info[:3])
    if sys.version_info.releaselevel != "final":
        version += _PRERELEASE_ABBREVS.get(
            sys.version_info.releaselevel, sys.version_info.releaselevel
        ) + str(sys.version_info.serial)
    return version


class VersionCheckTest(unittest.TestCase):
    def compile(self, expect_version=None):
        tmp = tempfile.mkdtemp(dir=os.environ.get("TEST_TMPDIR"))
        src = os.path.join(tmp, "mod.py")
        with open(src, "w") as f:
            f.write("x = 1\n")
        pycache = os.path.join(tmp, "__pycache__", "mod.cpython-00.pyc")
        os.makedirs(os.path.dirname(pycache))
        pyc = os.path.join(tmp, "mod.pyc")
        argv = [
            sys.executable,
            "-S",
            "-s",
            "-B",
            SCRIPT,
            "--src",
            src,
            "--pycache",
            pycache,
            "--dfile",
            "mod.py",
            "--pyc",
            pyc,
        ]
        if expect_version:
            argv += ["--expect-version", expect_version]
        result = subprocess.run(argv, capture_output=True, text=True)
        return result, pycache, pyc

    def assert_compiled(self, result, pycache, pyc):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(os.path.exists(pycache))
        self.assertTrue(os.path.exists(pyc))

    def test_no_expect_version(self):
        self.assert_compiled(*self.compile())

    def test_exact_version(self):
        self.assert_compiled(*self.compile(running_version()))

    def test_feature_version_only(self):
        self.assert_compiled(*self.compile("{}.{}".format(*sys.version_info[:2])))

    def test_different_micro_final(self):
        if sys.version_info.releaselevel != "final":
            self.skipTest("prerelease interpreters require exact version match")
        other_micro = "{}.{}.{}".format(
            sys.version_info.major, sys.version_info.minor, sys.version_info.micro + 1
        )
        self.assert_compiled(*self.compile(other_micro))

    def test_wrong_feature_version(self):
        result, pycache, pyc = self.compile("2.0.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected 2.0.0", result.stderr)
        self.assertFalse(os.path.exists(pycache))
        self.assertFalse(os.path.exists(pyc))

    def test_prerelease_expected_requires_exact(self):
        expected = "{}.{}.{}rc9".format(*sys.version_info[:3])
        if running_version() == expected:
            self.skipTest("interpreter is coincidentally the tested prerelease")
        result, pycache, pyc = self.compile(expected)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected " + expected, result.stderr)


if __name__ == "__main__":
    unittest.main()
