import os
import sys

# Each argv entry is KEY=VALUE — assert os.environ[KEY] == VALUE.
# Driven by sh_test args so per-target expectations live in BUILD.bazel.
for spec in sys.argv[1:]:
    key, _, want = spec.partition("=")
    got = os.environ.get(key)
    assert got == want, f"{key}: expected {want!r}, got {got!r}"

print(f"assert_env ok ({len(sys.argv) - 1} checks)")
