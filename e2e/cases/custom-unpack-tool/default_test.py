"""Runs without the flag: the default unpack.py must have installed the wheel.

The reference tool stamps dist-info INSTALLER with `aspect_rules_py`; the C
tool's marker here would mean the flag-gated custom toolchain leaked into the
default configuration."""

import pathlib

import iniconfig

site_packages = pathlib.Path(iniconfig.__file__).resolve().parent.parent
dist_infos = sorted(site_packages.glob("iniconfig-*.dist-info"))
assert len(dist_infos) == 1, "expected one iniconfig dist-info, found %s" % dist_infos

installer = dist_infos[0] / "INSTALLER"
assert installer.is_file(), "INSTALLER missing from %s" % dist_infos[0]
content = installer.read_text(encoding="utf-8")
assert content == "aspect_rules_py", (
    "unexpected INSTALLER content %r: custom unpack toolchain matched without its flag"
    % content
)
