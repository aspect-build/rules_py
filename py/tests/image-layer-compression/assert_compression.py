"""Assert built layer tars carry the compression their file name advertises.

Each `--expect SUFFIX` must match exactly one layer — usually
`_<group>.tar.<container>`, since one image can hold several layers in the same
container. `--absent SUFFIX` asserts no layer matches.
"""

import argparse
import sys
import tarfile
from typing import NoReturn

# libarchive picks the filter from the bsdtar flag, not the file name, so the
# leading bytes are what actually prove the flag reached the tar action.
MAGIC = {
    ".tar.gz": b"\x1f\x8b",
    ".tar.bz2": b"BZh",
    ".tar.xz": b"\xfd7zXZ\x00",
    ".tar.lzma": b"\x5d\x00\x00",
    ".tar.lz4": b"\x04\x22\x4d\x18",
    ".tar.zst": b"\x28\xb5\x2f\xfd",
    ".tar.Z": b"\x1f\x9d",
    # The fixture compressor's own container: a magic, then a gzip stream.
    ".tar.lolz": b"LOLZ",
}

# Containers the standard library can open get checked for real; the rest
# (zstd, lz4, .Z) stop at the magic check.
TARFILE_MODES = {
    ".tar": "r:",
    ".tar.gz": "r:gz",
    ".tar.bz2": "r:bz2",
    ".tar.xz": "r:xz",
    ".tar.lzma": "r:xz",
}

# The fixture compressor's container: strip its magic, and what is left is gzip.
# Unwrapping it proves the program's bytes reached the layer.
CUSTOM_PREFIX = {".tar.lolz": b"LOLZ"}


def fail(message: str) -> NoReturn:
    print("FAIL: {}".format(message), file=sys.stderr)
    sys.exit(1)


def find(paths: list[str], suffix: str) -> str:
    matches = [p for p in paths if p.endswith(suffix)]
    if not matches:
        fail("no layer ending in {} among {}".format(suffix, sorted(paths)))
    if len(matches) > 1:
        fail("{} matched more than one layer: {}".format(suffix, sorted(matches)))
    return matches[0]


def container_of(path: str) -> str:
    """The compression suffix of a layer file, e.g. `.tar.zst` for `x_grp.tar.zst`."""
    index = path.rindex(".tar")
    return path[index:]


def check(path: str) -> None:
    suffix = container_of(path)
    magic = MAGIC.get(suffix)
    if magic is not None:
        with open(path, "rb") as handle:
            head = handle.read(len(magic))
        if head != magic:
            fail("{} does not start with the {} magic {!r}, got {!r}".format(path, suffix, magic, head))

    prefix = CUSTOM_PREFIX.get(suffix)
    if prefix is not None:
        with open(path, "rb") as handle:
            handle.read(len(prefix))
            with tarfile.open(fileobj=handle, mode="r:gz") as archive:
                if not archive.getnames():
                    fail("{} unwrapped to an empty archive".format(path))
        return

    mode = TARFILE_MODES.get(suffix)
    if mode is None:
        return
    with tarfile.open(path, mode) as archive:
        if not archive.getnames():
            fail("{} decompressed to an empty archive".format(path))


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--expect", action="append", default=[])
    parser.add_argument("--absent", action="append", default=[])
    parser.add_argument("paths", nargs="+")
    args = parser.parse_args(argv)

    # Matching is by full suffix, so `--expect .tar` accepts only an
    # uncompressed layer.
    paths = [p for p in args.paths if ".tar" in p and not p.endswith(".mtree")]

    for suffix in args.expect:
        path = find(paths, suffix)
        check(path)
        print("ok: {} is a valid {} layer".format(path, container_of(path)))

    for suffix in args.absent:
        found = [p for p in paths if p.endswith(suffix)]
        if found:
            fail("expected no {} layer, found {}".format(suffix, sorted(found)))

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
