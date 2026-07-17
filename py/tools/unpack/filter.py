"""Copy an installed wheel tree, excluding site-packages-relative globs before compilation."""

import argparse
import csv
import stat
import shutil
import subprocess
from pathlib import Path

from exclude_glob import excluded, parse


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--from", dest="source", required=True, type=Path)
    parser.add_argument("--into", required=True, type=Path)
    parser.add_argument("--python-version-major", required=True, type=int)
    parser.add_argument("--python-version-minor", required=True, type=int)
    parser.add_argument("--exclude-glob", action="append", default=[], type=parse)
    parser.add_argument("--compile-pyc", action="store_true")
    parser.add_argument(
        "--pyc-invalidation-mode",
        default="checked-hash",
        choices=["checked-hash", "unchecked-hash", "timestamp"],
    )
    parser.add_argument("--python", type=Path)
    args = parser.parse_args()

    site_packages_relative = (
        Path("lib")
        / "python{}.{}".format(args.python_version_major, args.python_version_minor)
        / "site-packages"
    )
    source_site_packages = args.source / site_packages_relative

    def ignored(directory, names):
        try:
            parent = Path(directory).relative_to(source_site_packages)
        except ValueError:
            return []
        return [
            name
            for name in names
            if excluded((parent / name).parts, args.exclude_glob)
        ]

    shutil.copytree(args.source, args.into, symlinks=False, ignore=ignored, dirs_exist_ok=True)
    site_packages = args.into / site_packages_relative

    for record in site_packages.glob("*.dist-info/RECORD"):
        with record.open(newline="", encoding="utf-8") as stream:
            rows = [
                row
                for row in csv.reader(stream)
                if not row or not excluded(tuple(row[0].split("/")), args.exclude_glob)
            ]
        record.chmod(record.stat().st_mode | stat.S_IWRITE)
        record.unlink()
        with record.open("w", newline="", encoding="utf-8") as stream:
            csv.writer(stream).writerows(rows)

    if args.compile_pyc:
        if not args.python:
            raise SystemExit("--python is required when --compile-pyc is set")
        subprocess.run(
            [
                str(args.python),
                "-c",
                "import compileall; compileall.main()",
                "-q",
                "--invalidation-mode",
                args.pyc_invalidation_mode,
                "--",
                str(site_packages),
            ],
            check=True,
        )


if __name__ == "__main__":
    main()
