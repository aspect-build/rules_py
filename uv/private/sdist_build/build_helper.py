#!/usr/bin/env python3

from argparse import ArgumentParser
import shutil
import sys
from tempfile import mkdtemp
from os import chdir, getenv, listdir, path, execv, stat, mkdir
from subprocess import call

# Under Bazel, the source dir of a sdist to build is immutable. `build` and
# other tools however are constitutionally incapable of not writing to the
# source tree.
#
# As a workaround, we use this launcher which exists to do two things.
# - It makes a writable tempdir with a copy of the source tree
# - It punts to `build` targeting the tempdir

print(sys.executable, file=sys.stderr)

PARSER = ArgumentParser()
PARSER.add_argument("srcdir")
PARSER.add_argument("outdir")
opts, args = PARSER.parse_known_args()

t = getenv("TMPDIR")  # Provided by Bazel
print("Using tempdir", t, file=sys.stderr)

# Dirty awful way to prevent permissions from being replicated
shutil.copystat = lambda x, y, **k: None
shutil.copytree(opts.srcdir, t, dirs_exist_ok=True)

outdir = path.abspath(opts.outdir)

print(listdir(t), file=sys.stderr)
print(stat(t), file=sys.stderr)

call([
    sys.executable,
    "-m", "build",
    "--wheel",
    "--no-isolation",
    "--outdir", outdir,
], cwd=t)

print(listdir(outdir), file=sys.stderr)
