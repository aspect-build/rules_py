#!/usr/bin/env python3

import argparse
import hashlib
from pathlib import Path

PARSER = argparse.ArgumentParser(__name__)
PARSER.add_argument("--dir", type=Path, required=True)
PARSER.add_argument("--target", type=Path, required=True)


def compute_sha256(file_path):
    """Computes the SHA256 hash of a given file."""
    sha256_hash = hashlib.sha256()
    with open(file_path, "rb") as f:
        # Read and update hash string in chunks
        for byte_block in iter(lambda: f.read(4096), b""):
            sha256_hash.update(byte_block)
    return sha256_hash.hexdigest()


opts, args = PARSER.parse_known_args()

sha_map = {}
for file_path in args.dir.iterdir():
    if file_path.is_file():
        sha_map[file_path.name] = compute_sha256(file_path)
        
with open(args.target, "w") as f:
    f.write("RELEASED_BINARY_INTEGRITY = {!r}\n".format(sha_map))
