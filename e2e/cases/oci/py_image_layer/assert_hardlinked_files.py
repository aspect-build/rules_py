"""Filesystem hardlinks must not affect how regular files are archived."""

import sys
import tarfile


def main():
    found = set()
    for path in sys.argv[1:]:
        with tarfile.open(path) as archive:
            for member in archive:
                if member.name.endswith(("/hardlinked_data/a", "/hardlinked_data/b")):
                    assert member.isfile(), f"{member.name} was archived as a link"
                    assert archive.extractfile(member).read() == b"payload"
                    found.add(member.name.rsplit("/", 1)[1])
    assert found == {"a", "b"}, found


if __name__ == "__main__":
    main()
