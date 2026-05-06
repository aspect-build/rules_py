import sys

assert sys.flags.optimize == 1, "sys.flags.optimize={}, expected 1".format(sys.flags.optimize)
print("ok")
