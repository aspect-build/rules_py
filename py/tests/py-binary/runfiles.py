from bazel_tools.tools.python.runfiles import runfiles

location = runfiles.Create().Rlocation("aspect_rules_py/py/tests/py-binary/runfile.txt")
assert location != None
print(location)
