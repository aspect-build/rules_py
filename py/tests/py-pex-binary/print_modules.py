import sys
import cowsay
import six
import runfiles


r = runfiles.Create()
assert r is not None, "runfiles not found"
data_path = r.Rlocation("_main/py/tests/py-pex-binary/data.txt")
assert data_path is not None, "data.txt not found in runfiles"

# strings on one line to test presence for all
print(open(data_path).read()
      + ","
      + "/".join(cowsay.__file__.split("/")[-3:])
      + ","
      + "/".join(six.__file__.split("/")[-2:]))
