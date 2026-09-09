"""Checks the bytecode layout a launcher shipped, as found in the runfiles tree."""

import argparse
import os
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--mode", required=True, choices=["off", "pycache", "sourceless"])
parser.add_argument("--module", required=True)
parser.add_argument("--pyc-tag", default="")
parser.add_argument("--protect-source", action="store_true")
parser.add_argument("--no-sourceless", action="store_true")
parser.add_argument("--no-pycache", action="store_true")
parser.add_argument("--check-mappings", action="store_true")
parser.add_argument("--expect-suffix", action="append", default=[])
args = parser.parse_args()

root = Path(os.environ["RUNFILES_DIR"])
paths = [
    os.path.relpath(os.path.join(directory, name), root)
    for directory, _, names in os.walk(root / "_main")
    if "site-packages" not in directory
    for name in names
]

package, _, stem = args.module.rpartition("/")
prefix = "/" + package + "/" if package else "/"
has_source = any(p.endswith(prefix + stem + ".py") for p in paths)
has_sourceless = any(p.endswith(prefix + stem + ".pyc") for p in paths)
pycaches = [p for p in paths if (prefix + "__pycache__/" + stem + ".") in p and p.endswith(".pyc")]

assert has_source == (args.mode != "sourceless" or args.protect_source), ("source", has_source)
assert has_sourceless == (args.mode == "sourceless" and not args.no_sourceless), ("sourceless", has_sourceless)
assert bool(pycaches) == (args.mode == "pycache" and not args.no_pycache), ("pycache", pycaches)
if args.pyc_tag:
    assert any(p.endswith("{}.{}.pyc".format(stem, args.pyc_tag)) for p in pycaches), pycaches
for suffix in args.expect_suffix:
    assert any(p.endswith(suffix) for p in paths), suffix
if args.check_mappings:
    for mapped in (root / "_main" / "mapped.py", root / "root-mapped.py"):
        assert os.path.realpath(mapped).endswith("/entry_a.py"), mapped
print("layout ok")
