"""Assert that a collected-wheel directory contains every expected platform tag.

Usage: check_wheel_tags.py <dir> <expected-tag>...

Each expected tag is a substring that must appear in at least one wheel's
`Tag:` entries from its dist-info WHEEL metadata (filenames are analysis-time
names carrying no tags). A cross build that leaked the exec platform into its
wheel tag — the failure `pep517_native_whl`'s `--validate-anyarch` guards
against — shows up here as a missing tag.
"""

import os
import sys
import zipfile


def wheel_tags(path: str) -> list[str]:
    with zipfile.ZipFile(path) as zf:
        for name in zf.namelist():
            root, sep, rest = name.partition("/")
            if sep and root.endswith(".dist-info") and rest == "WHEEL":
                lines = zf.read(name).decode("utf-8").splitlines()
                return [
                    line.split(":", 1)[1].strip()
                    for line in lines
                    if line.startswith("Tag:")
                ]
    return []


def main() -> None:
    wheel_dir, expected = sys.argv[1], sys.argv[2:]
    names = sorted(f for f in os.listdir(wheel_dir) if f.endswith(".whl"))
    assert names, "no wheels collected under {}".format(wheel_dir)

    all_tags = []
    print("collected wheels:")
    for name in names:
        tags = wheel_tags(os.path.join(wheel_dir, name))
        all_tags.extend(tags)
        print("  {} [{}]".format(name, ", ".join(tags)))

    missing = [tag for tag in expected if not any(tag in t for t in all_tags)]
    if missing:
        raise AssertionError(
            "no collected wheel carries these tags: {}\ncollected: {}".format(missing, all_tags)
        )


if __name__ == "__main__":
    main()
