import importlib
import os

runfiles = importlib.import_module(os.environ["RUNFILES_MODULE"])
path = runfiles.Create().Rlocation("_main/py/tests/pyc-compile/runfiles_payload.txt")
assert path and open(path).read() == "payload\n", path
