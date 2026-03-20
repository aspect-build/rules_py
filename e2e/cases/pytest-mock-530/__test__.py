"""py_venv_test entry point — runs pytest on test_mock.py."""

import subprocess
import sys
import os


def main():
    test_file = os.path.join(os.path.dirname(__file__), "test_mock.py")
    rc = subprocess.run(
        [sys.executable, "-m", "pytest", test_file, "-v"],
    ).returncode
    sys.exit(rc)


if __name__ == "__main__":
    main()
