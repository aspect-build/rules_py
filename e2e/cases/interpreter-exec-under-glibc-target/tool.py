"""Trivial cfg=exec py_binary stand-in. The body doesn't matter; the test
asserts that the interpreter under which this runs can find its stdlib.
If Python's bootstrap can't import `encodings`, the action fails before
reaching this script — regression mode.

Also runs `verify_venv.verify_all()` so a venv-layout regression in the
exec-config interpreter shows up as a genrule failure with a precise
assertion message."""

import argparse
import sys

from verify_venv import verify_all

verify_all()

parser = argparse.ArgumentParser()
parser.add_argument("--output", required=True)
args = parser.parse_args()
with open(args.output, "w") as fh:
    fh.write("python " + sys.version + "\n")
