"""Bazel runfiles appropriate pth extensions.

Very carefully avoids resolving symlink path parts as doing so can result in
unintended escapes from runfiles sandbox trees.

"""

import os
import site

site_dir = os.path.dirname(__file__)

# FIXME: Are there other runfiles dir identification strategies that matter?
runfiles_dir = os.getenv("RUNFILES_DIR")
if not runfiles_dir:
    p = site_dir
    while p != "/":
        if p.endswith(".runfiles"):
            break
        p = os.path.dirname(p)
    else:
        raise RuntimeError("Failed to identify the runfiles root by path traversal!")
    runfiles_dir = p

# Now that we have the runfiles root, the required additional site paths are
# just the join of the runfiles root and the already bzlmod-transformed roots
# provided by the `rules_py` venv creation code. Join them and add them.
with open(os.path.join(site_dir, "_aspect.bzlpth")) as fp:
    for line in fp:
        line = line.strip()
        p = os.path.normpath(os.path.join(site_dir, line))
        # FIXME: Do we want to process embedded pth files? Or just insert
        # the paths into the sys.path
        site.addsitedir(p)
