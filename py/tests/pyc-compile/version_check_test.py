"""Tests for pyc_compile.py's argument contract and --expect-version guard."""

import importlib.util
import json
import marshal
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


def compiled_filename(pycache: str) -> str:
    with open(pycache, "rb") as f:
        return marshal.loads(f.read()[16:]).co_filename


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

    def test_accepted_versions(self) -> None:
        major, minor, micro = sys.version_info[:3]
        versions = [None, running_version(), "{}.{}".format(major, minor)]
        if sys.version_info.releaselevel == "final":
            versions.append("{}.{}.{}".format(major, minor, micro + 1))
        for version in versions:
            with self.subTest(version=version):
                self.setUp()
                self.assert_compiled(*self.compile(version))

    def test_rejected_versions(self) -> None:
        prerelease = "{}.{}.{}rc9".format(*sys.version_info[:3])
        for version in ["2.0.0"] + ([prerelease] if running_version() != prerelease else []):
            with self.subTest(version=version):
                result, pycache = self.compile(version)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("expected " + version, result.stderr)
                self.assertFalse(os.path.exists(pycache))

    def test_multiple_triples(self) -> None:
        one = triple(self.tmp, "one")
        two = triple(self.tmp, "two")
        result = self.run_compile(*one, *two)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(os.path.exists(one[1]))
        self.assertTrue(os.path.exists(two[1]))

    def test_bytecode_contract(self) -> None:
        source = (
            "def outer():\n"
            "    def inner():\n"
            "        return 41\n"
            "    return inner() + 1\n"
            "\n"
            "class K:\n"
            "    def m(self):\n"
            "        return outer()\n"
        )
        src = os.path.join(self.tmp, "contract.py")
        with open(src, "w") as f:
            f.write(source)
        pycache = os.path.join(self.tmp, "__pycache__", "contract.cpython-00.pyc")
        os.makedirs(os.path.dirname(pycache), exist_ok=True)
        result = self.run_compile(src, pycache, "pkg/contract.py")
        self.assertEqual(result.returncode, 0, result.stderr)
        with open(pycache, "rb") as f:
            data = f.read()
        # PEP 552 header: this interpreter's magic, unchecked hash-based flags, source hash.
        self.assertEqual(data[:4], importlib.util.MAGIC_NUMBER)
        self.assertEqual(int.from_bytes(data[4:8], "little"), 0b01)
        self.assertEqual(data[8:16], importlib.util.source_hash(source.encode()))
        code = marshal.loads(data[16:])
        filenames = set()
        pending = [code]
        while pending:
            current = pending.pop()
            filenames.add(current.co_filename)
            pending.extend(c for c in current.co_consts if isinstance(c, type(code)))
        self.assertEqual(filenames, {"pkg/contract.py"})
        namespace: dict[str, object] = {}
        exec(code, namespace)
        self.assertEqual(namespace["K"]().m(), 42)  # type: ignore[attr-defined]

    def test_sourceless_writes_colocated_copy(self) -> None:
        files = triple(self.tmp, "mod")
        sourceless = os.path.join(self.tmp, "mod.pyc")
        result = self.run_compile("--sourceless", *files)
        self.assertEqual(result.returncode, 0, result.stderr)
        with open(files[1], "rb") as cache, open(sourceless, "rb") as colocated:
            self.assertEqual(cache.read(), colocated.read())
        self.assertEqual(os.stat(files[1]).st_ino, os.stat(sourceless).st_ino)

    def test_sourceless_copy_replaces_existing_file(self) -> None:
        files = triple(self.tmp, "mod")
        sourceless = os.path.join(self.tmp, "mod.pyc")
        with open(sourceless, "wb") as f:
            f.write(b"stale")
        result = self.run_compile("--sourceless", *files)
        self.assertEqual(result.returncode, 0, result.stderr)
        with open(files[1], "rb") as cache, open(sourceless, "rb") as colocated:
            self.assertEqual(cache.read(), colocated.read())

    def test_sourceless_requires_pycache_output(self) -> None:
        src, _, dfile = triple(self.tmp, "mod")
        result = self.run_compile(
            "--sourceless", src, os.path.join(self.tmp, "mod.pyc"), dfile
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("__pycache__", result.stderr)

    def test_syntax_error_keeps_source_and_caret(self) -> None:
        files = triple(self.tmp, "broken")
        with open(files[0], "w") as f:
            f.write("def f():\n    return (1 + )\n")
        result = self.run_compile(*files)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('File "broken.py", line 2', result.stderr)
        self.assertIn("return (1 + )", result.stderr)
        self.assertIn("^", result.stderr)
        self.assertIn("SyntaxError: invalid syntax", result.stderr)
        self.assertFalse(os.path.exists(files[1]))

    def test_argfile(self) -> None:
        files = triple(self.tmp, "mod")
        argfile = os.path.join(self.tmp, "args")
        with open(argfile, "w") as f:
            f.write("\n".join(files) + "\n")
        self.assert_compiled(self.run_compile("@" + argfile), files[1])

    def test_at_sign_paths_are_positional(self) -> None:
        scope = os.path.join(self.tmp, "@scope")
        os.makedirs(scope)
        files = triple(scope, "mod")
        argfile = os.path.join(self.tmp, "args")
        with open(argfile, "w") as f:
            f.write("\n".join(files) + "\n")
        self.assert_compiled(self.run_compile("@" + argfile), files[1])
        self.assertEqual(compiled_filename(files[1]), "mod.py")

    def test_utf8_transport_under_ascii_locale(self) -> None:
        # ASCII filesystem paths, so only the argument transport carries UTF-8.
        src, pycache, _ = triple(self.tmp, "mod")
        dfile = "módulo.py"
        argfile = os.path.join(self.tmp, "args")
        with open(argfile, "w", encoding="utf-8") as f:
            f.write("\n".join([src, pycache, dfile]) + "\n")
        env = dict(
            os.environ, LC_ALL="C", LANG="C", PYTHONCOERCECLOCALE="0", PYTHONUTF8="0"
        )
        result = subprocess.run(PYTHON + ["@" + argfile], env=env, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", "replace"))
        self.assertEqual(compiled_filename(pycache), dfile)

        src, pycache, _ = triple(self.tmp, "worker")
        dfile = "wörker.py"
        request = json.dumps(
            {"requestId": 1, "arguments": [src, pycache, dfile]}, ensure_ascii=False
        )
        result = subprocess.run(
            PYTHON + ["--persistent_worker"],
            input=(request + "\n").encode("utf-8"),
            env=env,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", "replace"))
        self.assertEqual(json.loads(result.stdout)["exitCode"], 0, result.stdout)
        self.assertEqual(compiled_filename(pycache), dfile)

    def test_worker_survives_unexpected_errors(self) -> None:
        missing = os.path.join(self.tmp, "missing.py")
        good = triple(self.tmp, "good")
        requests = [
            {"requestId": 1, "arguments": [missing, good[1], "missing.py"]},
            {"requestId": 2, "arguments": good},
        ]
        result = subprocess.run(
            PYTHON + ["--persistent_worker"],
            input="".join(json.dumps(r) + "\n" for r in requests),
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        responses = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual([r["requestId"] for r in responses], [1, 2])
        self.assertEqual(responses[0]["exitCode"], 1)
        self.assertIn("missing.py", responses[0]["output"])
        self.assertEqual(responses[1]["exitCode"], 0)

    def test_worker_reports_warnings(self) -> None:
        files = triple(self.tmp, "warned")
        with open(files[0], "w") as f:
            f.write("def f(v):\n    return v is 1000\n")
        result = subprocess.run(
            PYTHON + ["--persistent_worker"],
            input=json.dumps({"requestId": 1, "arguments": files}) + "\n",
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        response = json.loads(result.stdout)
        self.assertEqual(response["exitCode"], 0, response)
        self.assertIn("SyntaxWarning", response["output"])
        self.assertIn("warned.py:2", response["output"])
        self.assertTrue(os.path.exists(files[1]))

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
