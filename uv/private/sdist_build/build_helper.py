#!/usr/bin/env python3

"""
A minimal python3 -m build wrapper

Mostly exists to allow debugging
"""

from argparse import ArgumentParser
import shutil
import sys
from os import getenv, listdir, path
from subprocess import check_call
from tempfile import TemporaryDirectory

PARSER = ArgumentParser()
PARSER.add_argument("srcarchive")
PARSER.add_argument("outdir")
PARSER.add_argument("--validate-anyarch", action="store_true")
PARSER.add_argument("--sandbox", action="store_true")
opts, args = PARSER.parse_known_args()

with TemporaryDirectory() as t:
    # Extract the source archive
    shutil.unpack_archive(opts.srcarchive, t)

    # Get a path to the outdir which will be valid after we cd
    outdir = path.abspath(opts.outdir)

    check_call([
        sys.executable,
        "-m", "build",
        "--wheel",
        "--no-isolation",
        "--outdir", outdir,
    ], cwd=t)

    inventory = listdir(outdir)

    if len(inventory) > 1:
        print("Error: Built more than one wheel!", file=sys.stderr)
        exit(1)

    if opts.validate_anyarch and not inventory[0].endswith("-none-any.whl"):
        print("Error: Target was anyarch but built a none-any wheel!")
        exit(1)
