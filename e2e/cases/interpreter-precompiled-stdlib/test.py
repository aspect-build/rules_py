"""The interpreter's standard library ships bytecode that is never rewritten,
unless the precompile flag is off."""

import os
import re
import sys
import unittest

# PEP 552: hash-based bytecode that Python never checks against its source.
_UNCHECKED_HASH = 0b01

# The standard library's directory in the interpreter's repository.
_STDLIB = re.compile(r"[^/]+/(Lib|lib/python3\.\d+t?)/")


def _runfiles() -> dict[str, str]:
    """Maps each runfiles path to the file it names."""
    manifest = os.environ.get("RUNFILES_MANIFEST_FILE")
    if manifest:
        runfiles = {}
        with open(manifest) as f:
            for line in f:
                path, _, target = line.rstrip("\n").partition(" ")
                runfiles[path] = target
        return runfiles
    root = os.environ["TEST_SRCDIR"]
    runfiles = {}
    for dirpath, _, filenames in os.walk(root):
        for name in filenames:
            target = os.path.join(dirpath, name)
            runfiles[os.path.relpath(target, root).replace(os.sep, "/")] = target
    return runfiles


class PrecompiledStdlibTest(unittest.TestCase):
    def test_stdlib_bytecode_is_unchecked_hash(self) -> None:
        # The interpreter's own paths resolve to the fetched repository, which
        # has every file, so look at the interpreter's files in the runfiles.
        bytecode = {}
        for path, target in _runfiles().items():
            if _STDLIB.match(path) and "/__pycache__/" in path and path.endswith(".pyc"):
                bytecode[_STDLIB.sub("", path, count=1)] = target
        if os.environ.get("PRECOMPILE") == "False":
            self.assertEqual(bytecode, {})
            return
        self.assertIn(f"__pycache__/os.{sys.implementation.cache_tag}.pyc", bytecode)
        for path, target in bytecode.items():
            with open(target, "rb") as f:
                flags = int.from_bytes(f.read(8)[4:8], "little")
            self.assertEqual(flags, _UNCHECKED_HASH, path)


if __name__ == "__main__":
    unittest.main()
