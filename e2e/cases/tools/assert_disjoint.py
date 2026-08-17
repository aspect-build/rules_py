"""Assert no file or symlink destination appears in more than one image layer.

Reads the listing emitted by the `assert_tar_listing` genrule. Directories
are exempt: every tar carries its own parent-directory rows.
"""

import re
import sys

# The pinned mtime anchors the destination path; the size column may be
# redacted to `*` for volatile rows.
_DATE = re.compile(r" Jan +1 +2023 ")


def main() -> int:
    listing_path = sys.argv[1]
    layer = None
    seen: dict[str, int] = {}
    duplicates: list[tuple[str, int, int]] = []
    parsed_rows = 0
    with open(listing_path) as listing:
        for line in listing:
            line = line.rstrip("\n")
            if line.startswith("layer: "):
                layer = int(line.split()[1])
                continue
            if not line.startswith("  - ") or layer is None:
                continue
            row = line[4:]
            if row.startswith("d"):
                continue
            match = _DATE.search(row)
            if match is None:
                return _fail(f"unparseable listing row (no date anchor): {line}")
            parsed_rows += 1
            destination = row[match.end():].split(" -> ")[0]
            if destination in seen:
                if seen[destination] != layer:
                    duplicates.append((destination, seen[destination], layer))
            else:
                seen[destination] = layer
    if parsed_rows == 0:
        return _fail(f"no rows parsed from {listing_path}")
    if duplicates:
        for destination, first, second in duplicates:
            print(
                f"FAIL: {destination} ships in both layer {first} and layer {second}",
                file=sys.stderr,
            )
        return 1
    return 0


def _fail(message: str) -> int:
    print("FAIL: " + message, file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
