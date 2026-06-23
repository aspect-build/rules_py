import os
import sys


expected = tuple(
    int(component)
    for component in os.environ["EXPECTED_PYTHON_VERSION"].split(".")
)
actual = sys.version_info[: len(expected)]
if actual != expected:
    raise AssertionError("expected Python {}, got {}".format(expected, actual))

constraint = os.environ["UV_CONSTRAINT_AT_LEAST_313"]
if constraint != "no":
    raise AssertionError(
        "expected the Python 3.12.13 target's >=3.13 UV constraint to be no, got {}".format(
            constraint
        )
    )
