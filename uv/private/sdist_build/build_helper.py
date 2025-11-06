#!/usr/bin/env python3

from argparse import ArgumentParser
from shutil import copytree
import sys
from tempfile import mkdtemp
from os import chdir, path
from runpy import run_module

# Under Bazel, the source dir of a sdist to build is immutable. `build` and
# other tools however are constitutionally incapable of not writing to the
# source tree.
#
# As a workaround, we use this launcher which exists to do two things.
# - It makes a writable tempdir with a copy of the source tree
# - It punts to `build` targeting the tempdir

PARSER = ArgumentParser()
PARSER.add_argument("srcdir")
PARSER.add_argument("outdir")
opts, args = PARSER.parse_known_args()

t = mkdtemp()
copytree(opts.srcdir, t, dirs_exist_ok=True)
outdir = path.abspath(opts.outdir)
sys.argv.pop()
sys.argv.pop()
sys.argv.extend([
    "--wheel",
    "--no-isolation",
    "--outdir", outdir,
    t,
])
run_module("build")
