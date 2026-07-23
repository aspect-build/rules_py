import os

from adder.add import add
from python.runfiles import runfiles

if __name__ == "__main__":
    adder_path = runfiles.Create().Rlocation("aspect_rules_py/py/tests/internal-deps/adder/add.py")
    if adder_path is None or not os.path.exists(adder_path):
        raise RuntimeError("could not resolve adder through runfiles")
    print("external {}".format(add(2, 3)))
