import cowsay
import sys
import os
from bazel_tools.tools.python.runfiles import runfiles

print("sys.path entries:")
for p in sys.path:
    print(" ", p)

print("")
print("os.environ entries:")
print(" runfiles dir:", os.environ.get("RUNFILES_DIR"))
print(" injected env:", os.environ.get("TEST"))

print("")
print("dir info: ")
print(" current dir:", os.curdir)
print(" current dir (absolute):", os.path.abspath(os.curdir))


r = runfiles.Create()
data_path = r.Rlocation("aspect_rules_py/examples/py_pex_binary/data.txt")

print("")
print("runfiles lookup:")
print(" data.txt:", data_path)

cowsay.cow(open(data_path).read())