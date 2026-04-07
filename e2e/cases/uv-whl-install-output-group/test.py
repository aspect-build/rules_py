"""Test that whl_install exposes install_dir via OutputGroupInfo.

filegroup(output_group="install_dir") is placed in py_venv_test's data so the
venv transition applies. If OutputGroupInfo.install_dir is not exposed, the
filegroup produces no files and the TreeArtifact is absent from TEST_SRCDIR.
"""

import os
import unittest


class WhlInstallOutputGroupTest(unittest.TestCase):
    def test_install_dir_accessible_via_output_group(self):
        srcdir = os.environ["TEST_SRCDIR"]
        # Find any .py file under the iniconfig install directory. The tree
        # artifact is placed somewhere under TEST_SRCDIR by Bazel's runfiles.
        found = []
        for root, _dirs, files in os.walk(srcdir):
            for f in files:
                path = os.path.join(root, f)
                if "iniconfig" in path and f.endswith(".py"):
                    found.append(path)

        self.assertGreater(
            len(found),
            0,
            "No iniconfig .py files found under TEST_SRCDIR — "
            "OutputGroupInfo.install_dir was not exposed or not propagated "
            "through filegroup(output_group='install_dir')\n"
            f"TEST_SRCDIR={srcdir}",
        )


if __name__ == "__main__":
    unittest.main()
