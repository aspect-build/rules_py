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

PARSER = ArgumentParser()
PARSER.add_argument("srcarchive")
PARSER.add_argument("outdir")
PARSER.add_argument("--validate-anyarch", action="store_true")
PARSER.add_argument("--patch-tool", default=None, help="Path to the patch binary")
PARSER.add_argument("--patch-strip", type=int, default=0, help="Strip count for patch (-p)")
PARSER.add_argument("--patch", action="append", default=[], dest="patches", help="Patch file to apply (repeatable)")
opts, args = PARSER.parse_known_args()

tmp_root = opts.outdir.lstrip("/") + ".tmp"
mkdir(tmp_root)

t = path.join(tmp_root, "worktree")

shutil.unpack_archive(opts.srcarchive, t)

# Annoyingly, unpack_archive creates a subdir in the target. Update t
# accordingly. Not worth the eng effort to prevent creating this dir.
t = path.join(t, listdir(t)[0])

if opts.patches:
    if not opts.patch_tool:
        print("Error: --patch-tool is required when --patch is specified", file=sys.stderr)
        exit(1)
    for patch_file in opts.patches:
        result = check_call(
            [opts.patch_tool, "-p{}".format(opts.patch_strip), "-i", path.abspath(patch_file)],
            cwd=t,
        )


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

    # FIXME: Shelling to setup.py is explicitly recommended against in modern
    # setuptools. Need to figure out a better story. The setuptools
    # recommendation seems to be 'pip wheel' which means we really want to
    # bifurcate this machinery into 'build with build' and 'build with pip' as
    # separate target types? What about 'build with uv' or another backend?
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
