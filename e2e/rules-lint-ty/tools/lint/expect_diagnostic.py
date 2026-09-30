"""Asserts that a ty report contains an expected diagnostic."""

import os
import re
import sys

with open(os.environ["TY_REPORT"]) as report_file:
    # Reports are colored; strip the escapes so matches don't depend on them.
    report = re.sub(r"\x1b\[[0-9;]*m", "", report_file.read())

expected = os.environ["EXPECTED_DIAGNOSTIC"]
if expected not in report:
    sys.exit(f"ty's report lacks {expected!r}:\n{report}")
