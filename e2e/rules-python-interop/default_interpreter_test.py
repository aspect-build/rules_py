"""Asserts an unpinned rules_py test runs on the rules_py-provisioned runtime.

3.12 is rules_python's default version, and this module registers a
`python_interpreters` 3.12 toolchain from its root MODULE — so resolving to
rules_py's runtime here proves the root registration outranks rules_python's.
"""

import sys


def main() -> None:
    assert sys.version_info[:2] == (3, 12), sys.version

    # Unresolved on purpose: realpath may chase Bazel's content-addressed
    # repo cache, losing the repo directory that identifies the provider.
    base = sys._base_executable or sys.executable
    assert "python_interpreters" in base and "python_3_12" in base, base
    print("underlying interpreter:", base)


main()
