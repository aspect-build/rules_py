"""Asserts py_pex_binary attrs are reflected in the built PEX artifact.

The shebang is the first line of the zipapp; inherit_path and
interpreter_constraints land in the PEX-INFO json at the zip root.
The default python_interpreter_constraints resolve {major}/{minor}
placeholders from the resolved toolchain, which is the same default
toolchain this test runs under, so expectations come from sys.version_info.
"""

import json
import sys
import zipfile

import runfiles

r = runfiles.Create()

PKG = "_main/py/tests/py-pex-binary"


def read_pex(name):
    path = r.Rlocation("{}/{}.pex".format(PKG, name))
    with open(path, "rb") as f:
        shebang = f.readline().rstrip(b"\r\n").decode()
    with zipfile.ZipFile(path) as zf:
        info = json.loads(zf.read("PEX-INFO"))
    return shebang, info


major, minor, micro = sys.version_info[:3]

# Defaults: stock shebang, no inherit-path, and the default
# "CPython=={major}.{minor}.*" constraint with placeholders substituted
# from the toolchain version.
shebang, info = read_pex("defaults_pex")
assert shebang == "#!/usr/bin/env python3", shebang
assert info.get("inherit_path", "false") == "false", info
expected = "CPython=={}.{}.*".format(major, minor)
assert info["interpreter_constraints"] == [expected], (
    info["interpreter_constraints"],
    expected,
)

# Custom values: shebang override, inherit_path=prefer, and full
# {major}.{minor}.{patch} placeholder substitution.
shebang, info = read_pex("custom_pex")
assert shebang == "#!/opt/custom/bin/python3", shebang
assert info["inherit_path"] == "prefer", info
expected = "CPython=={}.{}.{}".format(major, minor, micro)
assert info["interpreter_constraints"] == [expected], (
    info["interpreter_constraints"],
    expected,
)

# Remaining inherit_path attr values.
_, info = read_pex("inherit_fallback_pex")
assert info["inherit_path"] == "fallback", info

_, info = read_pex("inherit_false_pex")
assert info.get("inherit_path", "false") == "false", info

print("PASS")
