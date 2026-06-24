import os
import sys
import sysconfig
from pathlib import Path

expected_version = tuple(map(int, sys.argv[1].split(".")))
expected_freethreaded = sys.argv[2] == "1"
expected_interpreter = sys.argv[3]

if not os.path.samefile(sys.executable, expected_interpreter):
    raise SystemExit(
        f"expected interpreter {expected_interpreter}, got {sys.executable}"
    )
if sys.version_info[:2] != expected_version:
    raise SystemExit(
        f"expected Python {expected_version}, got {sys.version_info[:2]}"
    )
actual_freethreaded = bool(sysconfig.get_config_var("Py_GIL_DISABLED"))
if actual_freethreaded != expected_freethreaded:
    raise SystemExit(
        f"expected free-threaded={expected_freethreaded}, "
        f"got {actual_freethreaded}"
    )

Path(sys.argv[4]).touch()
