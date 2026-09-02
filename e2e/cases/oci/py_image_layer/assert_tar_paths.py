"""Assert expected paths across a set of OCI layer tar archives."""

import argparse
import tarfile


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--contains", action="append", default=[])
    parser.add_argument("--absent", action="append", default=[])
    parser.add_argument("--count", action="append", default=[])
    parser.add_argument("--tar-contains", action="append", default=[])
    parser.add_argument("--tar-absent", action="append", default=[])
    parser.add_argument("--tar-mode", action="append", default=[])
    parser.add_argument("--interpreter-python-count", type=int)
    parser.add_argument("archives", nargs="+")
    args = parser.parse_args()

    paths: list[str] = []
    for archive in args.archives:
        with tarfile.open(archive, "r:*") as tar:
            paths.extend(tar.getnames())

    for expected in args.contains:
        if not any(expected in path for path in paths):
            parser.error("missing path containing {!r}".format(expected))

    for unexpected in args.absent:
        if any(path.endswith(unexpected) for path in paths):
            parser.error("unexpected path ending in {!r}".format(unexpected))

    for spec in args.count:
        expected, separator, count = spec.rpartition("=")
        if not separator:
            parser.error("--count must be PATH_SUBSTRING=COUNT")
        actual = sum(expected in path for path in paths)
        if actual != int(count):
            parser.error("expected {} paths containing {!r}, found {}".format(count, expected, actual))

    for spec in args.tar_contains:
        suffix, separator, expected = spec.partition("=")
        if not separator:
            parser.error("--tar-contains must be TAR_SUFFIX=PATH_SUBSTRING")
        archive = next((path for path in args.archives if path.endswith(suffix)), None)
        if archive is None:
            parser.error("missing archive ending in {!r}".format(suffix))
        with tarfile.open(archive, "r:*") as tar:
            if not any(expected in path for path in tar.getnames()):
                parser.error("missing path containing {!r} in {!r}".format(expected, suffix))

    for spec in args.tar_absent:
        suffix, separator, unexpected = spec.partition("=")
        if not separator:
            parser.error("--tar-absent must be TAR_SUFFIX=PATH_SUBSTRING")
        archive = next((path for path in args.archives if path.endswith(suffix)), None)
        if archive is None:
            parser.error("missing archive ending in {!r}".format(suffix))
        with tarfile.open(archive, "r:*") as tar:
            if any(unexpected in path for path in tar.getnames()):
                parser.error("unexpected path containing {!r} in {!r}".format(unexpected, suffix))
    for spec in args.tar_mode:
        suffix, separator, rest = spec.partition("=")
        expected, separator2, mode = rest.partition("=")
        if not separator or not separator2:
            parser.error("--tar-mode must be TAR_SUFFIX=PATH_SUBSTRING=OCTAL_MODE")
        archive = next((path for path in args.archives if path.endswith(suffix)), None)
        if archive is None:
            parser.error("missing archive ending in {!r}".format(suffix))
        with tarfile.open(archive, "r:*") as tar:
            members = [member for member in tar.getmembers() if expected in member.name]
        if not members:
            parser.error("missing path containing {!r} in {!r}".format(expected, suffix))
        for member in members:
            if (member.mode & 0o777) != int(mode, 8):
                parser.error(
                    "expected mode {} for {!r} in {!r}, found {:o}".format(
                        mode, member.name, suffix, member.mode & 0o777
                    )
                )

    if args.interpreter_python_count is not None:
        actual = sum("python_interpreters" in path and path.endswith("/bin/python") for path in paths)
        if actual != args.interpreter_python_count:
            parser.error("expected {} interpreter bin/python paths, found {}".format(args.interpreter_python_count, actual))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
