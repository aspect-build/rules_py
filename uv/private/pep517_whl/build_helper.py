#!/usr/bin/env python3

"""
A minimal python3 -m build wrapper

Accepts a pre-extracted and pre-patched source directory and runs
`python -m build` to produce a wheel.
"""

from argparse import ArgumentParser
import os
import sys
from os import listdir, path
from subprocess import CalledProcessError, STDOUT, run
from tempfile import TemporaryFile

PARSER = ArgumentParser()
PARSER.add_argument("srcdir", help="Path to pre-extracted source directory")
PARSER.add_argument("outdir", help="Output directory for the built wheel")
PARSER.add_argument("--validate-anyarch", action="store_true")
opts, args = PARSER.parse_known_args()

# Verify source directory exists
srcdir = path.abspath(opts.srcdir)
if not path.isdir(srcdir):
    print(f"Error: Source directory '{srcdir}' does not exist!", file=sys.stderr)
    sys.exit(1)

# Copy source to a writable temp directory because setuptools may need to write
# egg-info or other metadata files into the source tree during build.
import os
import shutil
import stat
import tempfile
writable_srcdir = path.join(tempfile.mkdtemp(prefix="build_src_"), "src")
shutil.copytree(srcdir, writable_srcdir, dirs_exist_ok=True)
for root, dirs, files in os.walk(writable_srcdir):
    for d in dirs:
        os.chmod(os.path.join(root, d), stat.S_IRWXU)
    for f in files:
        os.chmod(os.path.join(root, f), stat.S_IRUSR | stat.S_IWUSR)
srcdir = writable_srcdir

# Get a path to the outdir which will be valid after we cd
outdir = path.abspath(opts.outdir)

# Preserve PATH so native sdist builds can find compilers (clang, gcc).
build_env = dict(os.environ)

if path.exists(path.join(srcdir, "pyproject.toml")) or path.exists(path.join(srcdir, "setup.py")):
    # Always use `python -m build` (PEP 517 frontend). For setup.py-only
    # packages without a pyproject.toml, build creates a minimal PEP 517
    # shim automatically. --no-isolation ensures it uses the deps we've
    # already provided in the build venv rather than trying to pip-install.
    cmd = [
        sys.executable,
        "-m", "build",
        "--wheel",
        "--no-isolation",
        "--outdir", outdir,
    ]
else:
    print("Error: Unable to detect build command! Neither pyproject.toml nor setup.py found!", file=sys.stderr)
    sys.exit(1)

with TemporaryFile(mode="w+") as build_log:
    try:
        run(cmd, cwd=srcdir, env=build_env, stdout=build_log, stderr=STDOUT, check=True)
    except CalledProcessError:
        build_log.seek(0)
        output = build_log.read()
        if output:
            sys.stderr.write(output)
            if not output.endswith("\n"):
                sys.stderr.write("\n")
        print(f"Error: Build failed!\nSee {srcdir} for the sandbox", file=sys.stderr)
        sys.exit(1)

inventory = listdir(outdir)

if len(inventory) > 1:
    print(f"Error: Built more than one wheel!\nSee {outdir} for the sandbox", file=sys.stderr)
    sys.exit(1)

if opts.validate_anyarch and not inventory[0].endswith("-none-any.whl"):
    print(f"Error: Target was anyarch but built a none-any wheel!\nSee {outdir} for the sandbox", file=sys.stderr)
    sys.exit(1)
