import os
import sys

# Generic env-assertion runner. Each argv entry is one of:
#   KEY=VALUE  → assert os.environ[KEY] == VALUE
#   !KEY       → assert KEY not in os.environ
#
# Driven by the `args` attr on each consumer, so per-target
# expectations live next to the `env =` declaration in BUILD.bazel.
for spec in sys.argv[1:]:
    if spec.startswith("!"):
        key = spec[1:]
        assert key not in os.environ, (
            f"{key} should be unset, got {os.environ.get(key)!r}"
        )
    else:
        key, _, want = spec.partition("=")
        got = os.environ.get(key)
        assert got == want, f"{key}: expected {want!r}, got {got!r}"

print(f"entry_env ok ({os.environ['BAZEL_TARGET_NAME']})")
