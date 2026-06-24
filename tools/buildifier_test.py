import os
import subprocess
import tempfile
from pathlib import Path
import unittest

from tools.buildifier import _discover_files


class BuildifierTest(unittest.TestCase):
    def test_discovers_starlark_files_and_prunes_generated_snapshots(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            expected = {
                "BUILD",
                "BUILD.bazel",
                "MODULE.bazel",
                "Tiltfile",
                "WORKSPACE",
                "WORKSPACE.bazel",
                "package/BUCK",
                "package/config.axl",
                "package/defs.bzl",
                "package/extension.MODULE.bazel",
                "package/rules.star",
            }
            for path in expected | {
                ".git/internal.bzl",
                "package/module.py",
                "package/snapshots/generated.BUILD.bazel",
            }:
                output = root / path
                output.parent.mkdir(parents=True, exist_ok=True)
                output.touch()

            self.assertEqual(set(_discover_files(root)), expected)
            self.assertEqual(_discover_files(root / "package" / "snapshots"), [])

    def test_tree_walk_formats_sources_without_rewriting_snapshots(self):
        buildifier_rlocation = os.environ.get("RULES_PY_BUILDIFIER")
        if buildifier_rlocation is None:
            self.skipTest("requires the Bazel buildifier target")
        from python.runfiles import runfiles

        runtime_files = runfiles.Create()
        if runtime_files is None:
            self.fail("cannot locate test runfiles")
        buildifier = runtime_files.Rlocation(buildifier_rlocation)
        if buildifier is None:
            self.fail("cannot locate the buildifier wrapper")

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "BUILD.bazel"
            snapshot = root / "package" / "snapshots" / "generated.BUILD.bazel"
            snapshot.parent.mkdir(parents=True)
            unformatted = 'foo(name="foo")\n'
            source.write_text(unformatted)
            snapshot.write_text(unformatted)

            command = [buildifier]
            result = subprocess.run(
                [*command, "-mode=check", "--rules-py-discover"],
                cwd=root,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(source.read_text(), unformatted)
            self.assertEqual(snapshot.read_text(), unformatted)

            subprocess.run(
                [*command, "--rules-py-discover"],
                cwd=root,
                check=True,
            )

            self.assertEqual(source.read_text(), 'foo(name = "foo")\n')
            self.assertEqual(snapshot.read_text(), unformatted)


if __name__ == "__main__":
    unittest.main()
