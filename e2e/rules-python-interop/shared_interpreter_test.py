"""Asserts the test runs on the rules_python-provisioned 3.12 runtime.

Run as the main of both rules_py and rules_python py_test targets to prove
both rule families share the same underlying interpreter binary.
"""

import sys


def main() -> None:
    assert sys.version_info[:2] == (3, 12), sys.version

    # Unresolved on purpose: realpath may chase Bazel's content-addressed
    # repo cache, losing the repo directory that identifies the provider.
    base = sys._base_executable or sys.executable
    assert "rules_python" in base and "python_3_12" in base, base
    print("underlying interpreter:", base)


main()
