"""pyvenv.cfg `home` for a system-interpreter (interpreter_path) toolchain
must be the interpreter's bin dir, not the venv's own bin.
See the package BUILD.bazel for the regression story.
"""

import os

cfg = os.path.join(
    os.environ["TEST_SRCDIR"],
    os.environ["TEST_WORKSPACE"],
    "cases/interpreter-local-pyvenv-home/.venv_sys/pyvenv.cfg",
)
with open(cfg) as f:
    content = f.read()

assert "home = /opt/{fake-python}/bin\n" in content, content
print("OK")
