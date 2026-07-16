"""Asserts the interpreter version the caller selected via a version flag.

The expected "major.minor" is passed as argv[1]. The version is chosen by the
caller's build flag (see test.sh), not by a python_version attr on the target,
so this exercises flag inheritance rather than the per-target attr.
"""

import sys


def main():
    expected = sys.argv[1]
    major, minor = (int(part) for part in expected.split("."))
    actual = sys.version_info[:2]
    if actual != (major, minor):
        sys.exit(
            "expected Python {}, got {}.{}".format(expected, actual[0], actual[1])
        )
    print("Python {} OK".format(expected))


if __name__ == "__main__":
    main()
