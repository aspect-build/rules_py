"""Sourceless bytecode carries a pseudo filename, so its tracebacks never print
lines from an unrelated file at the same relative path; with the source shipped
CPython rewrites the filename to the real one."""

import os
import traceback

import raiser

decoy = os.path.join(os.environ["TEST_TMPDIR"], "cwd")
os.makedirs(os.path.join(decoy, "pycache"))
with open(os.path.join(decoy, "pycache", "raiser.py"), "w") as f:
    f.write("UNRELATED = 1\nUNRELATED_LINE_TWO = 2\n")
os.chdir(decoy)

try:
    raiser.boom()
except RuntimeError:
    text = traceback.format_exc()

if os.environ["EXPECT_PYC"] == "sourceless":
    assert 'File "<pyc/raiser.py>"' in text, text
    assert "UNRELATED" not in text, text
else:
    assert raiser.__file__ in text, text
    assert 'raise RuntimeError("boom")' in text, text
print("OK")
