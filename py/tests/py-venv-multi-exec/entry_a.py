import os
import sys

import shared_lib

assert shared_lib.GREETING == "hello from the shared venv"

target = os.environ["BAZEL_TARGET_NAME"]

if target == "test_optimize":
    assert not __debug__, f"expected -O to disable __debug__, got __debug__={__debug__}"
elif target == "test_non_isolated":
    assert sys.flags.isolated == 0, f"expected isolated=0 (-I dropped), got {sys.flags.isolated}"
else:
    assert __debug__, "expected default debug mode"
    assert sys.flags.isolated == 1, f"expected isolated=1, got {sys.flags.isolated}"

print(f"entry_a ok ({target})")
