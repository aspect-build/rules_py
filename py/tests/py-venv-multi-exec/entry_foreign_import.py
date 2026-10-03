"""A src listed from another package imports its bytecode from that package's path.
Files are checked before the import so the interpreter cannot have written the cache itself."""

import os
import sys

foreign_dir = os.path.join(os.path.dirname(__file__), "cross-pkg")
names = set(os.listdir(foreign_dir))
caches = os.listdir(os.path.join(foreign_dir, "__pycache__")) if "__pycache__" in names else []

if os.environ["EXPECT_PYC"] == "sourceless":
    assert names >= {"foreign_source.pyc"} and "foreign_source.py" not in names, names
else:
    assert "foreign_source.py" in names and any(c.startswith("foreign_source.") for c in caches), (names, caches)

sys.path.insert(0, foreign_dir)
import foreign_source

assert foreign_source.VALUE == "foreign direct source", foreign_source.VALUE
print("foreign import ok")
