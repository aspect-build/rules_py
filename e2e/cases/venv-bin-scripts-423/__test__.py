#!/usr/bin/env python3

"""Test that dependency packages are usable (issue #423).

Adapted for the new py_test architecture: verifies the dice package
is importable and its entry point works correctly.
"""

import dice

# Verify the dice module is importable and functional
result = dice.roll("1d6")
# dice.roll returns a Roll object; convert to int
value = int(result)
assert 1 <= value <= 6, f"Expected roll result 1-6, got {value}"

print(f"roll 1d6 = {value}")
print("All dependency import tests passed.")
