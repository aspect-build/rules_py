import os
import sys
import site

print("---")
print("__file__:", __file__)
print("sys.prefix:", sys.prefix)
print("sys.executable:", sys.executable)
print("site.PREFIXES:")
for p in site.PREFIXES:
    print(" -", p)

# The virtualenv module should have already been loaded at interpreter startup
assert "_virtualenv" in sys.modules

# And we should have at least two site packages roots
assert len(site.getsitepackages()) >= 2

# And the user site flag should be set
assert site.ENABLE_USER_SITE
