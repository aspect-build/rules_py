"""The wheel's install tree, built for a Linux target platform, must have been
installed by the C unpack tool running on the executor."""

import os
import pathlib

runfiles = pathlib.Path(os.environ["TEST_SRCDIR"])
installers = sorted(runfiles.glob("**/iniconfig-*.dist-info/INSTALLER"))
assert len(installers) == 1, "expected one iniconfig install tree, found %s" % installers

content = installers[0].read_text(encoding="utf-8")
assert content == "rules_py-e2e-c-unpack-tool\n", (
    "unexpected INSTALLER content %r: wheel was not installed by the C tool" % content
)

site_packages = installers[0].parent.parent
pycs = list((site_packages / "iniconfig" / "__pycache__").glob("__init__.*.pyc"))
assert pycs, "no compiled bytecode: --compile-pyc did not run under the exec interpreter"
