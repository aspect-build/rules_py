import cowsay
import sys
import os
import runfiles

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
assert r is not None, "runfiles not found"
data_path = r.Rlocation("_main/data.txt")
assert data_path is not None, "data.txt not found in runfiles"

print("")
print("runfiles lookup:")
print(" data.txt:", data_path)

print(cowsay.get_output_string("cow", open(data_path).read()))