import os
import sys


expected = tuple(int(part) for part in os.environ["EXPECTED_PYTHON_VERSION"].split("."))
if sys.version_info[:2] != expected:
    raise AssertionError(f"expected Python {expected}, got {sys.version_info[:2]}")

constraint = os.environ["UV_CONSTRAINT_AT_LEAST_313"]
expected_constraint = "yes" if expected >= (3, 13) else "no"
if constraint != expected_constraint:
    raise AssertionError(
        f"expected the >=3.13 UV constraint to be {expected_constraint}, got {constraint}"
    )
