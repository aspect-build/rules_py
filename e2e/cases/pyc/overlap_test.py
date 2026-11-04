"""Two libraries list shared_lib.py. Every module, the main included, loads its
bytecode from its natural runfiles path, beside or in place of the source."""

import importlib.util
import os
import sys

import shared_lib

mode = os.environ["EXPECT_PYC"]
package = os.sep + os.path.join("_main", "pyc") + os.sep

main = sys.modules["__main__"].__file__
assert main.endswith(package + "overlap_test" + (".pyc" if mode == "sourceless" else ".py")), main

if mode == "sourceless":
    assert shared_lib.__file__.endswith(package + "shared_lib.pyc"), shared_lib.__file__
    assert not os.path.exists(shared_lib.__file__[: -len(".pyc")] + ".py"), "source shipped beside sourceless bytecode"
else:
    assert shared_lib.__file__.endswith(package + "shared_lib.py"), shared_lib.__file__
    with open(shared_lib.__cached__, "rb") as f:
        assert f.read(4) == importlib.util.MAGIC_NUMBER, shared_lib.__cached__

assert shared_lib.GREETING == "hello from the shared venv"
