"""Run each `record_path_*` binary and assert they all resolved
`cowsay.__file__` to the same on-disk path.

A hub package reached from consumers at differing `dep_group` settings
should still be compiled once. If the @pypi hub recompiles cowsay per
consumer, each binary's runfiles point at a config-specific install and the
resolved paths diverge."""

from pathlib import Path
import subprocess
import sys

BINARIES = [
    "record_path_dev",
    "record_path_unit_tests",
]


def main() -> None:
    paths = {}
    for name in BINARIES:
        binary = Path(__file__).with_name(name)
        result = subprocess.run(
            [str(binary)],
            check=True,
            capture_output=True,
            text=True,
        )
        paths[name] = result.stdout.strip()

    unique = set(paths.values())
    if len(unique) != 1:
        detail = "\n".join("  {} -> {}".format(name, path) for name, path in paths.items())
        sys.exit(
            "Expected cowsay to be compiled once across all dep_group consumers, "
            "but observed multiple resolved install paths:\n" + detail
        )

    print("OK: single resolved path observed:", next(iter(unique)))


if __name__ == "__main__":
    main()
