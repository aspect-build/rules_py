"""Import probe for #1378, run by test.sh under one runfiles source at a time.

Reports enough of the interpreter's view to tell *why* an import failed: which
python ran, whether the venv was entered at all, and what ended up on sys.path.
"""

import os
import sys

print("sys.executable:", sys.executable)
print("sys.prefix:", sys.prefix)
print("VIRTUAL_ENV:", os.environ.get("VIRTUAL_ENV"))
print("RUNFILES_DIR:", os.environ.get("RUNFILES_DIR"))
print("RUNFILES_MANIFEST_FILE:", os.environ.get("RUNFILES_MANIFEST_FILE"))

failures = []

try:
    import cowsay  # noqa: F401
except ImportError as e:
    failures.append("third-party import failed: " + str(e))
else:
    print("third-party import OK: cowsay")

try:
    from firstparty.greet import GREETING
except ImportError as e:
    failures.append("first-party import failed: " + str(e))
else:
    print("first-party import OK:", GREETING)

if failures:
    print("sys.path:", file=sys.stderr)
    for p in sys.path:
        print("   ", p, "EXISTS" if os.path.exists(p) else "MISSING", file=sys.stderr)
    for f in failures:
        print("FAIL:", f, file=sys.stderr)
    sys.exit(1)

print("PASS: both first-party and third-party imports resolved")
