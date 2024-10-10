import sys
import cowsay
import six
from bazel_tools.tools.python.runfiles import runfiles


r = runfiles.Create()
data_path = r.Rlocation("aspect_rules_py/py/tests/py-pex-binary/data.txt")

# strings on one line to test presence for all
print(open(data_path).read()
      + ","
      + "/".join(cowsay.__file__.split("/")[-3:])
      + ","
      + "/".join(six.__file__.split("/")[-2:]))
