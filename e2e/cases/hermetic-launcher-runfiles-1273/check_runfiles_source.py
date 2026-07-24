"""Runfiles-source-selection probe for hermetic-launcher >= 0.0.13 (see test.sh).

Driven under a mixed-source environment where BOTH `RUNFILES_DIR` (a real
runfiles tree, whose venv-python is a *relative* symlink into the interpreter
repo) and `RUNFILES_MANIFEST_FILE` (the manifest, whose entries point at
physical bazel-out copies) are exported. hermetic-launcher PR #59 makes the
directory win in that tie: the launcher must both *resolve* the venv through
the tree and *export the directory* to this child. The 0.0.11 launcher picked
the manifest instead, so `sys.prefix` landed on a physical output and
`RUNFILES_MANIFEST_FILE` (not `RUNFILES_DIR`) reached the child.
"""

import os
import sys

failures = []

# The venv must resolve through the logical runfiles tree, not a physical output.
if ".runfiles" not in sys.prefix:
    failures.append(
        "sys.prefix resolved to a physical output instead of the runfiles tree: "
        + sys.prefix
    )

# The directory owns the environment exported to the child: RUNFILES_DIR set,
# RUNFILES_MANIFEST_FILE scrubbed.
runfiles_dir = os.environ.get("RUNFILES_DIR")
manifest_file = os.environ.get("RUNFILES_MANIFEST_FILE")
if not runfiles_dir:
    failures.append("RUNFILES_DIR was not exported to the child")
elif ".runfiles" not in runfiles_dir:
    failures.append("RUNFILES_DIR does not point at a runfiles tree: " + runfiles_dir)
if manifest_file:
    failures.append(
        "RUNFILES_MANIFEST_FILE leaked to the child (manifest won): " + manifest_file
    )

print("sys.prefix:", sys.prefix)
print("RUNFILES_DIR:", runfiles_dir)
print("RUNFILES_MANIFEST_FILE:", manifest_file)

if failures:
    for f in failures:
        print("FAIL:", f, file=sys.stderr)
    sys.exit(1)

print("PASS: runfiles directory won source selection")
