import sys

import greeting

print(greeting.greet(sys.argv[1] if len(sys.argv) > 1 else "world"))
