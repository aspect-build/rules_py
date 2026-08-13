import os
import sys

assert sys.version_info[:2] == (3, 9), sys.version_info

# The shim must have loaded at interpreter startup via _virtualenv.pth.
assert "_virtualenv" in sys.modules

# The shim must be a real file inside the venv, not a symlink resolving into
# the rules_py source tree — symlinked copies dangle outside Bazel (tar/OCI).
shim = os.path.realpath(sys.modules["_virtualenv"].__file__)
assert shim.endswith("site-packages/_virtualenv.py"), shim

# The shim's meta_path finder patches distutils config parsing so legacy
# [install] keys cannot redirect installs outside the venv.
import distutils.dist  # noqa: E402

dist = distutils.dist.Distribution()
opts = dist.get_option_dict("install")
opts["prefix"] = ("setup.cfg", "/tmp/elsewhere")
opts["install_scripts"] = ("setup.cfg", "/tmp/elsewhere/bin")
dist.parse_config_files([])
assert opts["prefix"][1] == os.path.abspath(sys.prefix), opts["prefix"]
assert "install_scripts" not in opts, opts
