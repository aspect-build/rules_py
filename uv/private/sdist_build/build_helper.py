#!/usr/bin/env python3

from argparse import ArgumentParser
import shutil
import sys
from os import getenv, listdir, path, execv
from subprocess import check_call, CalledProcessError

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

# Dirty awful way to prevent permissions from being replicated
shutil.copystat = lambda x, y, **k: None
shutil.copytree(opts.srcdir, t, dirs_exist_ok=True)

for e in sys.path:
    print(" -", e, file=sys.stderr)
    
execv(sys.executable, [
    "-m", "build",
    "--wheel",
    "--no-isolation",
    "--outdir", opts.outdir,
])
