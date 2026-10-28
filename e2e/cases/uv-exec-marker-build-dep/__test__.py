import sys

import docopt

assert sys.version_info[:2] == (3, 10), sys.version_info
assert docopt.__doc__ is not None
print("ok")
