import os
import sys

# Mirror how jupyter_core / nbconvert locate wheel data files: resolve a
# resource relative to sys.prefix/share (the venv's data root).
SHARE_FILE = os.path.join(sys.prefix, "share", "sharedata", "hello.txt")

# The `data` scheme installs relative to sys.prefix, not just under share/:
# a second prefix root, and a file at the prefix itself.
ETC_FILE = os.path.join(sys.prefix, "etc", "sharedata", "config.json")
ROOT_FILE = os.path.join(sys.prefix, "toplevel.txt")
