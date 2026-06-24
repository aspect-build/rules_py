#!/usr/bin/env python3

"""Test that dependency bin scripts are linked into the venv bin/ directory (issue #423)."""

import os
import subprocess
import sys

venv = os.environ.get("VIRTUAL_ENV")
assert venv, "VIRTUAL_ENV is not set"

bin_dir = os.path.join(venv, "bin")
roll_script = os.path.join(bin_dir, "roll")

# Verify the roll script exists in the venv bin/ directory
assert os.path.exists(roll_script), (
    f"Expected 'roll' script at {roll_script} but it does not exist. "
    f"bin/ contents: {os.listdir(bin_dir)}"
)

# Verify it's executable
assert os.access(roll_script, os.X_OK), (
    f"'roll' script at {roll_script} is not executable"
)

# Verify it actually runs
result = subprocess.run(
    [roll_script, "1d6"],
    capture_output=True,
    text=True,
)
assert result.returncode == 0, (
    f"'roll 1d6' failed with rc={result.returncode}: {result.stderr}"
)

# The output is in the form "[N]" where N is a number between 1 and 6
output = result.stdout.strip()
assert output.startswith("[") and output.endswith("]"), (
    f"Unexpected roll output format: {output!r}"
)
value = int(output[1:-1])
assert 1 <= value <= 6, f"Expected roll result 1-6, got {value}"

invoke_script = os.path.join(bin_dir, "invoke")
assert os.path.exists(invoke_script), f"Expected 'invoke' script at {invoke_script}"
assert os.access(invoke_script, os.X_OK), (
    f"'invoke' script at {invoke_script} is not executable"
)

# Invoke publishes `invoke.main:program.run`, which requires resolving the
# dotted object path after importing the module.
invoke_result = subprocess.run(
    [invoke_script, "--version"],
    capture_output=True,
    text=True,
)
assert invoke_result.returncode == 0, (
    f"'invoke --version' failed with rc={invoke_result.returncode}: "
    f"{invoke_result.stderr}"
)
assert invoke_result.stdout.strip() == "Invoke 2.2.0", invoke_result.stdout

print(f"roll 1d6 = {value}")
print("All venv bin script tests passed.")
