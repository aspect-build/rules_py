"""Runs with --//custom-unpack-tool:use_custom_unpack=true: the wheel must
have been installed by the C unpack tool, not the default unpack.py."""

import pathlib

import iniconfig

site_packages = pathlib.Path(iniconfig.__file__).resolve().parent.parent
dist_infos = sorted(site_packages.glob("iniconfig-*.dist-info"))
assert len(dist_infos) == 1, "expected one iniconfig dist-info, found %s" % dist_infos

installer = dist_infos[0] / "INSTALLER"
assert installer.is_file(), (
    "INSTALLER missing: the custom C unpack tool did not run (%s)" % installer
)
content = installer.read_text(encoding="utf-8")
assert content == "rules_py-e2e-c-unpack-tool\n", (
    "unexpected INSTALLER content %r: wheel was not installed by the C tool" % content
)
assert (dist_infos[0] / "REQUESTED").is_file()

# whl_install passes --compile-pyc by default; the C tool must have run
# compileall under the exec interpreter.
pycs = list((site_packages / "iniconfig" / "__pycache__").glob("__init__.*.pyc"))
assert pycs, "no compiled bytecode: the C tool skipped --compile-pyc"
