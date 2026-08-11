"""Assert that a collected-wheel directory contains every expected platform tag.

Usage: check_wheel_tags.py <dir> <expected-tag>...

Each expected tag is a substring that must appear in at least one wheel
filename. A cross build that leaked the exec platform into its wheel tag —
the failure `pep517_native_whl`'s `_validate_wheel_platform` guards against —
shows up here as a missing tag.
"""

import os
import sys


def main() -> None:
    wheel_dir, expected = sys.argv[1], sys.argv[2:]
    names = sorted(f for f in os.listdir(wheel_dir) if f.endswith(".whl"))
    assert names, "no wheels collected under {}".format(wheel_dir)

    print("collected wheels:")
    for name in names:
        print("  " + name)

    missing = [tag for tag in expected if not any(tag in name for name in names)]
    if missing:
        raise AssertionError(
            "no collected wheel carries these tags: {}\ncollected: {}".format(missing, names)
        )


if __name__ == "__main__":
    main()
