"""Tests for pyc_compile.py's argument contract and --expect-version guard."""

import json
import os
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.environ["PYC_COMPILE"]
PYTHON = [sys.executable, "-S", "-s", "-B", SCRIPT]

_PRERELEASE_ABBREVS = {"alpha": "a", "beta": "b", "candidate": "rc"}


def running_version() -> str:
    version = "{}.{}.{}".format(*sys.version_info[:3])
    if sys.version_info.releaselevel != "final":
        version += _PRERELEASE_ABBREVS.get(
            sys.version_info.releaselevel, sys.version_info.releaselevel
        ) + str(sys.version_info.serial)
    return version


def triple(tmp: str, name: str) -> list[str]:
    src = os.path.join(tmp, name + ".py")
    with open(src, "w") as f:
        f.write("x = 1\n")
    pycache = os.path.join(tmp, "__pycache__", name + ".cpython-00.pyc")
    os.makedirs(os.path.dirname(pycache), exist_ok=True)
    return [src, pycache, name + ".py"]


class VersionCheckTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.mkdtemp(dir=os.environ.get("TEST_TMPDIR"))

    def run_compile(self, *argv: str) -> "subprocess.CompletedProcess[str]":
        return subprocess.run(PYTHON + list(argv), capture_output=True, text=True)

    def compile(
        self, expect_version: str | None = None
    ) -> tuple["subprocess.CompletedProcess[str]", str]:
        files = triple(self.tmp, "mod")
        argv = ["--expect-version", expect_version] if expect_version else []
        return self.run_compile(*argv, *files), files[1]

    def assert_compiled(
        self, result: "subprocess.CompletedProcess[str]", pycache: str
    ) -> None:
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(os.path.exists(pycache))

    def test_no_expect_version(self) -> None:
        self.assert_compiled(*self.compile())

    def test_exact_version(self) -> None:
        self.assert_compiled(*self.compile(running_version()))

    def test_feature_version_only(self) -> None:
        self.assert_compiled(*self.compile("{}.{}".format(*sys.version_info[:2])))

    def test_different_micro_final(self) -> None:
        if sys.version_info.releaselevel != "final":
            self.skipTest("prerelease interpreters require exact version match")
        other_micro = "{}.{}.{}".format(
            sys.version_info.major, sys.version_info.minor, sys.version_info.micro + 1
        )
        self.assert_compiled(*self.compile(other_micro))

    def test_wrong_feature_version(self) -> None:
        result, pycache = self.compile("2.0.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected 2.0.0", result.stderr)
        self.assertFalse(os.path.exists(pycache))

    def test_prerelease_expected_requires_exact(self) -> None:
        expected = "{}.{}.{}rc9".format(*sys.version_info[:3])
        if running_version() == expected:
            self.skipTest("interpreter is coincidentally the tested prerelease")
        result, _ = self.compile(expected)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected " + expected, result.stderr)

    def test_multiple_triples(self) -> None:
        one = triple(self.tmp, "one")
        two = triple(self.tmp, "two")
        result = self.run_compile(*one, *two)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(os.path.exists(one[1]))
        self.assertTrue(os.path.exists(two[1]))

    def test_argfile(self) -> None:
        files = triple(self.tmp, "mod")
        argfile = os.path.join(self.tmp, "args")
        with open(argfile, "w") as f:
            f.write("\n".join(files) + "\n")
        self.assert_compiled(self.run_compile("@" + argfile), files[1])

    def test_incomplete_triple(self) -> None:
        result = self.run_compile(*triple(self.tmp, "mod")[:2])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("triples", result.stderr)

    def test_persistent_worker(self) -> None:
        good = triple(self.tmp, "good")
        bad = triple(self.tmp, "bad")
        requests = [
            {"requestId": 1, "arguments": good},
            {"requestId": 2, "arguments": ["--expect-version", "2.0.0", *bad]},
            {"requestId": 3, "cancel": True},
            {"requestId": 4, "arguments": triple(self.tmp, "again")},
        ]
        result = subprocess.run(
            PYTHON + ["--persistent_worker"],
            input="".join(json.dumps(r) + "\n" for r in requests),
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        responses = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual([r["requestId"] for r in responses], [1, 2, 4])
        self.assertEqual(responses[0]["exitCode"], 0)
        self.assertEqual(responses[2]["exitCode"], 0)
        self.assertEqual(responses[1]["exitCode"], 1)
        self.assertIn("expected 2.0.0", responses[1]["output"])
        self.assertTrue(os.path.exists(good[1]))
        self.assertFalse(os.path.exists(bad[1]))


if __name__ == "__main__":
    unittest.main()
