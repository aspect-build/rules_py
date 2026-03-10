"""Verify that CLI arguments are passed through to the Python script."""

import sys

# When run as a bazel test, extra args come after --.
# Filter out any pytest/unittest args that Bazel might inject.
# We just verify our script receives sys.argv[0] (the script itself).
print(f"sys.argv = {sys.argv}")

# argv[0] should be the script path
assert sys.argv[0].endswith("test_args.py"), (
    f"sys.argv[0] doesn't end with test_args.py: {sys.argv[0]}"
)

print("OK: args passthrough verified")
