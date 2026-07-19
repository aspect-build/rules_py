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


def read_pex(name: str) -> tuple[str, dict[str, object]]:
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


# print_modules_pex has real deps (a venv + wheels), so it exercises the
# structural exclusions: the sibling venv's `.pth`/`pyvenv.cfg` plumbing and the
# interpreter must be filtered out, while first-party `data` files are kept.
def pex_names(name: str) -> list[str]:
    path = r.Rlocation("{}/{}.pex".format(PKG, name))
    with zipfile.ZipFile(path) as zf:
        return zf.namelist()


names = pex_names("print_modules_pex")

venv_plumbing = [
    n
    for n in names
    if n.endswith("pyvenv.cfg") or n.endswith(".pth") or ".venv/" in n
]
assert not venv_plumbing, venv_plumbing

interpreter = [n for n in names if "python_interpreters" in n]
assert not interpreter, interpreter[:10]

# The wheels arrive as `--dependency` under `.deps/`, not as loose sources.
assert any(n.startswith(".deps/") and "cowsay" in n for n in names), "cowsay missing from .deps/"

# A wheel's install-tree must be packaged only once (as a `--dependency` under
# `.deps/`); a duplicate `--source` would reappear under its `whl_install` path.
install_tree_dupes = [n for n in names if "whl_install" in n]
assert not install_tree_dupes, install_tree_dupes[:10]

# Plain data files travel with the sources (transitive_sources is .py-only).
assert any(n.endswith("/data.txt") for n in names), "data.txt missing from pex"

print("PASS")
