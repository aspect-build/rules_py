#!/usr/bin/env python3

import sys
import os

_repo_mapping = {}

def pathadd(path: str, workspace=""):
    """Attempt to soundly append a path to the sys.path.

    See https://github.com/aspect-build/rules_py/issues/573 for gorey details.

    Because of Bazel's symlinking behavior and `exec()` file canonicalization,
    the `sys.prefix` and site dir may escape from `.runfiles/` as created by
    Bazel. This is a problem for a ton of reasons, notably that source files
    aren't copied to `bazel-bin`, so relative paths from the (canonicalized!)
    site dir back "up" to firstparty sources may be broken.

    Yay.

    As a workaround, this codepath exists to try and use `$RUNFILES_DIR` (either
    set by Bazel or enforced by the Aspect venv `activate` script) as the basis
    for appending runfiles-relative logical paths to the `sys.path`.

    """

    runfiles_dir = os.getenv("RUNFILES_DIR")
    if not runfiles_dir:
        print("{} ERROR: Unable to identify the runfiles root!".format(__file__))
        exit(1)

    # Parse the repo mapping file if it exists
    if not _repo_mapping:
        repo_mapping_file = os.path.join(runfiles_dir, "_repo_mapping")
        if os.path.exists(repo_mapping_file):
            with open(repo_mapping_file, "r") as fp:
                for line in fp:
                    line = line.strip()
                    c, a, mca = line.split(",")
                    _repo_mapping[(c, a)] = mca

    # Deal with looking up a remapped repo name
    # HACK: This assumes the built binary is in the main workspace
    if _repo_mapping:
        repo, path = path.split("/", 1)
        repo = _repo_mapping[(workspace, repo)]
        path = os.path.join(repo, path)
        
    path = os.path.normpath(os.path.join(runfiles_dir, path))
    if path not in sys.path:
        sys.path.append(path)
