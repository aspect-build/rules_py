"""Fail unless every bytecode file carries a PEP 552 checked-hash header.

Usage: pyc_check.py @ARGFILE, whose lines are STAMP then each PYC.

Writes STAMP when all PYC files are checked-hash, so a validation action can
depend on bytecode another ruleset produced.
"""

import sys

with open(sys.argv[1][1:], encoding="utf-8") as f:
    stamp, *pycs = f.read().splitlines()
unchecked = []
for path in pycs:
    with open(path, "rb") as f:
        # Flags bit 0: hash-based; bit 1: checked.
        if int.from_bytes(f.read(8)[4:8], "little") != 0b11:
            unchecked.append(path)
if unchecked:
    sys.exit(
        "--@aspect_rules_py//py:pyc_invalidation_mode=checked-hash cannot reuse bytecode "
        "that is not checked-hash: {}. Set precompile_invalidation_mode = \"checked_hash\" "
        "on the rules_python library that precompiles it, or disable its precompilation.".format(
            ", ".join(unchecked)
        )
    )
open(stamp, "w").close()
