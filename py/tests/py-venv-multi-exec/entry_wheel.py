import os

import cowsay

target = os.environ["BAZEL_TARGET_NAME"]

# Both consumers share the same wheel install via `:shared_venv`'s
# deps — the wheel resolves once at venv-assembly time.
output = cowsay.get_output_string("cow", f"hello from {target}")
assert "hello from" in output
assert target in output

print(f"entry_wheel ok ({target})")
