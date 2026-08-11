"""Assert py_library DefaultInfo.files carries only direct sources.

argv[1] is a manifest of $(SRCS) from a genrule consuming :top, whose
srcs list another py_library (:__mid_lib). The expansion must yield
top's app.py plus mid's direct mid.py — never leaf.py, which is only
reachable transitively through mid's deps.
"""

import sys

with open(sys.argv[1]) as f:
    files = f.read().split()

basenames = sorted(p.rsplit("/", 1)[-1] for p in files)
assert basenames == ["app.py", "mid.py"], basenames
print("ok")
