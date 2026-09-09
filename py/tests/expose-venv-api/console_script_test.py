import os
import sys

wrapper = os.path.join(os.path.dirname(sys.executable), "cowsay")
expected = sys.argv[1] == "present"
assert os.path.exists(wrapper) == expected, (wrapper, expected)
