"""Assert each bytecode path appears once across image layers, with given PEP 552 flags.

Usage: assert_image_pyc_flags.py --expect PATH_SUBSTRING=FLAGS... [--absent PATH_SUBSTRING...] ARCHIVE...
"""

import argparse
import tarfile

parser = argparse.ArgumentParser()
parser.add_argument("--expect", action="append", default=[])
parser.add_argument("--absent", action="append", default=[])
parser.add_argument("archives", nargs="+")
args = parser.parse_args()

members = []
for archive in args.archives:
    with tarfile.open(archive, "r:*") as tar:
        for member in tar.getmembers():
            if member.isfile() and member.name.endswith(".pyc"):
                members.append((member.name, tar.extractfile(member).read(8)))

for spec in args.expect:
    expected, _, flags = spec.rpartition("=")
    found = [(name, header) for name, header in members if expected in name]
    if len(found) != 1:
        parser.error("expected one entry containing {!r}, found {}".format(expected, [name for name, _ in found]))
    actual = int.from_bytes(found[0][1][4:8], "little")
    if actual != int(flags):
        parser.error("{} has flags {}, expected {}".format(found[0][0], actual, flags))

for unexpected in args.absent:
    leaked = [name for name, _ in members if unexpected in name]
    if leaked:
        parser.error("unexpected bytecode {}".format(leaked))
