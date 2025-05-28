#!/usr/bin/env python3

"""%(prog)s [options]

Helper to create a symlink to a virtualenv in the source tree.
"""

import argparse
import os
import sys
import site
from pathlib import Path

virtualenv_home = os.path.realpath(os.environ["VIRTUAL_ENV"])
virtualenv_name = os.path.basename(virtualenv_home)
runfiles_dir = os.path.realpath(os.environ["RUNFILES_DIR"])
builddir = os.path.realpath(os.environ["BUILD_WORKING_DIRECTORY"])

# Chop off the runfiles tree prefix
virtualenv_path = virtualenv_home.lstrip(runfiles_dir).lstrip("/")
# Chop off the repo name to get a repo-relative path
virtualenv_path = virtualenv_path[virtualenv_path.find("/"):]

PARSER = argparse.ArgumentParser(
    prog="link",
    usage=__doc__,
)

PARSER.add_argument(
    "--venv-name",
    dest="venv_name",
    default=virtualenv_name,
    help="Name to link the virtualenv under.",
)

PARSER.add_argument(
    "--dest",
    dest="dest",
    default=os.path.join(builddir, os.path.dirname(virtualenv_path)),
    help="Dir to link the virtualenv into",
)

if __name__ == "__main__":
    opts = PARSER.parse_args()
    dest = Path(os.path.join(opts.dest, opts.venv_name))
    print("""\
Linking: {venv_home} -> {venv_path}

To activate the virtualenv run:
    source {venv_path}/bin/activate
""".format(
    venv_home = virtualenv_home,
    venv_path = dest,
))

    if dest.exists() and dest.is_symlink() and dest.readlink() == Path(virtualenv_home):
        print("Link is up to date!")
        exit(0)

    else:
        try:
            dest.lstat()
            dest.unlink()
        except FileNotFoundError:
            pass
    
        # From -> to
        dest.symlink_to(virtualenv_home, target_is_directory=True)
        print("Link created!")
        exit(0)
