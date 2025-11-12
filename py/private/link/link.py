#!/usr/bin/env python3

"""%(prog)s [options]

Helper to create a symlink to a virtualenv in the source tree.
"""

import argparse
import os
from pathlib import Path


def munge_venv_name(target_package, virtualenv_name):
    acc = (target_package or "").replace("/", "+")
    if acc:
        acc += "+"
    acc += virtualenv_name.lstrip(".")
    return "." + acc
    

if __name__ == "__main__":
    virtualenv_home = os.path.normpath(os.environ["VIRTUAL_ENV"])
    virtualenv_name = os.path.basename(virtualenv_home)
    builddir = os.path.normpath(os.environ["BUILD_WORKING_DIRECTORY"])
    target_package, target_name = os.environ["BAZEL_TARGET"].split("//", 1)[1].split(":")

    PARSER = argparse.ArgumentParser(
        prog="link",
        usage=__doc__,
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )

    PARSER.add_argument(
        "--dest",
        dest="dest",
        default=builddir,
        help="Dir to link the virtualenv into. Default is $BUILD_WORKING_DIRECTORY.",
    )

    PARSER.add_argument(
        "--name",
        dest="name",
        default=munge_venv_name(target_package, virtualenv_name),
        help="Name to link the virtualenv as.",
    )
    
    opts = PARSER.parse_args()
    dest = Path(os.path.join(opts.dest, opts.name))
    print("""

Linking: {venv_home} -> {venv_path}
""".format(
    venv_home = virtualenv_home,
    venv_path = dest,
))

    if dest.exists() and dest.is_symlink() and dest.readlink() == Path(virtualenv_home):
        print("Link is up to date!")

    else:
        try:
            dest.lstat()
            dest.unlink()
        except FileNotFoundError:
            pass

        # From -> to
        dest.symlink_to(virtualenv_home, target_is_directory=True)
        print("Link created!")

    print("""
To configure the virtualenv in your IDE, configure an interpreter with the homedir
    {venv_path}

    Please note that you may encounter issues if your editor doesn't evaluate
    the `activate` script. If you do please file an issue at
    https://github.com/aspect-build/rules_py/issues/new?template=BUG-REPORT.yaml

To activate the virtualenv in your shell run
    source {venv_path}/bin/activate

virtualenvwrapper users may further want to
    $ ln -s {venv_path} $WORKON_HOME/{venv_name}
""".format(
    venv_home = virtualenv_home,
    venv_name = opts.name,
    venv_path = dest,
))
