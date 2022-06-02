try:
    from bazel_tools.tools.python.runfiles import runfiles
except ModuleNotFoundError as err:
    assert False, "Expected to be able to import runfiles helper"
