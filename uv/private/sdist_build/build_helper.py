#!/usr/bin/env python3

"""
A minimal python3 -m build wrapper

Mostly exists to allow debugging.
"""

from argparse import ArgumentParser
import os
import shutil
import sys
from os import listdir, mkdir, path
from subprocess import CalledProcessError, check_call

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
    
    # Inherit the action environment (Bazel controls what's available) and
    # override temp directories so build artifacts stay in the sandbox.
    env = dict(os.environ)
    env.update({
        "TMP": tmp_root,
        "TEMP": tmp_root,
        "TEMPDIR": tmp_root,
    })

    # When the Python interpreter was built with a hermetic toolchain (e.g.
    # rules_foreign_cc + toolchains_llvm), sysconfig contains absolute sandbox
    # paths and toolchain-specific flags that won't work in a new sandbox.
    # Detect this and override CC/CFLAGS/LDSHARED so distutils can compile
    # C extensions with the system compiler.
    import sysconfig
    cc = sysconfig.get_config_var("CC")
    if cc and not path.exists(cc.split()[0]):
        env.setdefault("CC", "cc")
        env.setdefault("CFLAGS", "")
        env.setdefault("LDFLAGS", "")
        env.setdefault("LDSHARED", "cc -shared")

    check_call(cmd, cwd=t, env=env)
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
