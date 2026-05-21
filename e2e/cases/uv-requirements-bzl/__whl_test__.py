"""Verify a wheel file resolved via :whl / all_whl_requirements_by_package
is actually on disk in test runfiles."""

import glob
import os
import sys

runfiles_dir = os.environ.get("RUNFILES_DIR") or sys.argv[0] + ".runfiles"
wheels = glob.glob(os.path.join(runfiles_dir, "**", "*.whl"), recursive=True)
assert wheels, "no .whl files found in runfiles under " + runfiles_dir
print("wheel file(s) on disk via :whl data dep:")
for w in wheels:
    print("  " + w)
