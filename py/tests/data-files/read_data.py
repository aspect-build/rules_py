"""Assert `data` files reach the launcher target.

Regression test: the `py_binary` / `py_test` macros must forward `data`
to the generated launcher rule, not only to the sibling py_venv —
otherwise `$(location :data_file)` expansion in `args` fails analysis
and the launcher's own runfiles miss the files.

Checks, in order:
1. `data.txt` is present in the runfiles tree.
2. If argv[1] is given (the `args = ["$(location :data.txt)"]`
   expansion), it resolves to the same file.
3. If `DATA_LOCATION` is set (the `env` expansion), it resolves too.
"""

import os
import sys

EXPECTED = "hello from data file"


def read(path: str) -> str:
    with open(path) as f:
        return f.read().strip()


# 1. Runfiles presence.
rfdir = os.environ.get("RUNFILES_DIR")
if not rfdir:
    sys.exit("RUNFILES_DIR not set")
workspace = os.environ.get("BAZEL_WORKSPACE", "_main")
runfiles_path = os.path.join(rfdir, workspace, "py", "tests", "data-files", "data.txt")
if not os.path.exists(runfiles_path):
    sys.exit("data file missing from runfiles: " + runfiles_path)
assert read(runfiles_path) == EXPECTED

# 2. `args` location expansion (workspace-relative, resolved from cwd).
if len(sys.argv) > 1:
    assert read(sys.argv[1]) == EXPECTED, sys.argv[1]

# 3. `env` location expansion.
env_path = os.environ.get("DATA_LOCATION")
if env_path:
    assert read(env_path) == EXPECTED, env_path

print("ok")
