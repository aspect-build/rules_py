import cowsay
import sys
import os

print("sys.path entries:")
for p in sys.path:
    print(p)


print(os.environ)

cowsay.cow('hello py_binary zip!')