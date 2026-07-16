"""Materialize declared venv site-packages symlinks from a parameter file."""

import os
import sys
from pathlib import Path


def main(params):
    entries = Path(params).read_text().splitlines()
    if len(entries) % 2:
        raise ValueError("expected output/target pairs")
    for output, target in zip(entries[::2], entries[1::2]):
        Path(output).parent.mkdir(parents=True, exist_ok=True)
        os.symlink(target, output)


if __name__ == "__main__":
    main(sys.argv[1])
