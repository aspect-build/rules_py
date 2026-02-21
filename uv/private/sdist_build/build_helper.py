#!/usr/bin/env python3

"""
A minimal python3 -m build wrapper

Mostly exists to allow debugging.
"""

from argparse import ArgumentParser
import shutil
import sys
from os import listdir, mkdir, path
from subprocess import CalledProcessError, check_call
from tempfile import TemporaryDirectory

PARSER = ArgumentParser()
PARSER.add_argument("srcarchive")
PARSER.add_argument("outdir")
PARSER.add_argument("--validate-anyarch", action="store_true")
opts, args = PARSER.parse_known_args()

tmp_root = opts.outdir.lstrip("/") + ".tmp"
mkdir(tmp_root)

t = path.join(tmp_root, "worktree")

shutil.unpack_archive(opts.srcarchive, t)

# Annoyingly, unpack_archive creates a subdir in the target. Update t
# accordingly. Not worth the eng effort to prevent creating this dir.
t = path.join(t, listdir(t)[0])

# Get a path to the outdir which will be valid after we cd
outdir = path.abspath(opts.outdir)

try:
    if path.exists(path.join(t, "pyproject.toml")):
        cmd = [
            sys.executable,
            "-m", "build",
            "--wheel",
            "--no-isolation",
            "--outdir", outdir,
        ]
    elif path.exists(path.join(t, "setup.py")):
        cmd = [
            sys.executable,
            path.realpath(path.join(t, "setup.py")),
            "bdist_wheel",
            "--dist-dir",
            outdir,
        ]
    else:
        print("Error: Unable to detect build command! Neither pyproject nor setup.py found!", file=sys.stderr)
        exit(1)    
    
    check_call(cmd,
    cwd=t,
    env={
        "TMP": tmp_root,
        "TEMP": tmp_root,
        "TEMPDIR": tmp_root,
    })
except CalledProcessError:
    print("Error: Build failed!\nSee {} for the sandbox".format(t), file=sys.stderr)
    exit(1)

inventory = listdir(outdir)

if len(inventory) > 1:
    print("Error: Built more than one wheel!\nSee {} for the sandbox".format(t), file=sys.stderr)
    exit(1)

if opts.validate_anyarch and not inventory[0].endswith("-none-any.whl"):
    print("Error: Target was anyarch but built a none-any wheel!\nSee {} for the sandbox".format(t), file=sys.stderr)
    exit(1)
