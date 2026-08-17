"""Assert a symlink in one layer resolves to a file shipped by another layer."""

import argparse
import posixpath
import sys
import tarfile


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--link-tar", required=True)
    parser.add_argument("--link-suffix", required=True)
    parser.add_argument("--target-tar", required=True)
    parser.add_argument("archives", nargs="+")
    args = parser.parse_args()

    link_tar = next(path for path in args.archives if path.endswith(args.link_tar))
    target_tar = next(path for path in args.archives if path.endswith(args.target_tar))
    with tarfile.open(link_tar, "r:*") as archive:
        member = next(item for item in archive.getmembers() if item.name.endswith(args.link_suffix))
    if not member.issym() or member.linkname.startswith("/"):
        print("FAIL: symlink was not preserved as a relative link", file=sys.stderr)
        return 1
    target = posixpath.normpath(posixpath.join(posixpath.dirname(member.name), member.linkname))
    with tarfile.open(target_tar, "r:*") as archive:
        target_paths = {posixpath.normpath(item.name) for item in archive.getmembers()}
    if target not in target_paths:
        print("FAIL: symlink does not resolve to a target-layer file", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
