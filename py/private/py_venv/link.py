#!/usr/bin/env python3

"""%(prog)s [options]

Helper to link a target's runfiles tree into the source tree.
"""

import argparse
import os
import sys
import site
from pathlib import Path


def munge_venv_name(target_package, virtualenv_name):
    acc = (target_package or "").replace("/", "+")
    if acc:
        acc += "+"
    acc += virtualenv_name.lstrip(".")
    return "." + acc
    

if __name__ == "__main__":
    try:
        runfiles_dir = Path(os.path.abspath(os.environ["RUNFILES_DIR"]))
    except KeyError:
        raise SystemExit(
            "py_venv_link requires directory-based runfiles (RUNFILES_DIR)"
        ) from None
    if not runfiles_dir.is_dir():
        raise SystemExit(
            "py_venv_link RUNFILES_DIR is not a directory: {}".format(runfiles_dir)
        )

    virtualenv_relative = Path(
        os.environ["BAZEL_WORKSPACE"],
        os.environ["VIRTUAL_ENV"],
    )
    virtualenv_home = runfiles_dir / virtualenv_relative
    if not virtualenv_home.is_dir():
        raise SystemExit(
            "py_venv_link virtualenv is not a directory: {}".format(virtualenv_home)
        )

    virtualenv_name = virtualenv_home.name
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
        help="Directory in which to create the runfiles link. Default is $BUILD_WORKING_DIRECTORY.",
    )

    PARSER.add_argument(
        "--name",
        dest="name",
        default=munge_venv_name(target_package, virtualenv_name),
        help="Name of the workspace-local runfiles link.",
    )
    
    opts = PARSER.parse_args()
    runfiles_link = Path(opts.dest, opts.name)
    virtualenv_path = runfiles_link / virtualenv_relative
    print("""

Linking runfiles: {runfiles_dir} -> {runfiles_link}
Virtualenv: {venv_path}
""".format(
    runfiles_dir = runfiles_dir,
    runfiles_link = runfiles_link,
    venv_path = virtualenv_path,
))

    if (
        runfiles_link.exists()
        and runfiles_link.is_symlink()
        and runfiles_link.readlink() == runfiles_dir
    ):
        print("Link is up to date!")

    else:
        try:
            runfiles_link.lstat()
            runfiles_link.unlink()
        except FileNotFoundError:
            pass

        # From -> to
        runfiles_link.symlink_to(runfiles_dir, target_is_directory=True)
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
    venv_name = opts.name,
    venv_path = virtualenv_path,
))
