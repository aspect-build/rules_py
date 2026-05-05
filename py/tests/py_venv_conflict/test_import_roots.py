#!/usr/bin/env python3

import os
for k, v in os.environ.items():
    if k.startswith("BUILD_") or k.startswith("RUNFILES_"):
        print(k, ":", v)

print("---")

from pathlib import Path

# prefix components:
space =  '    '
branch = '|   '
# pointers:
tee =    '+-- '
last =   '+-- '


def tree(dir_path: Path, prefix: str=''):
    """A recursive generator, given a directory Path object
    will yield a visual tree structure line by line
    with each line prefixed by the same characters
    """    
    contents = list(dir_path.iterdir())
    # contents each get pointers that are ├── with a final └── :
    pointers = [tee] * (len(contents) - 1) + [last]
    for pointer, path in zip(pointers, contents):
        yield prefix + pointer + path.name
        if path.is_dir(): # extend the prefix and recurse:
            extension = branch if pointer == tee else space 
            # i.e. space because last, └── , above so no more |
            yield from tree(path, prefix=prefix+extension)

here = Path(".")
print(here.absolute().resolve())
for line in tree(here):
    print(line)

print("---")

import sys
for e in sys.path:
    print("-", e)

print("---")

print(sys.prefix)

# Verify that conflicting modules are importable and originate from one
# of our `a/` or `b/` fixtures. The venv assembly routes non-PyWheelsInfo
# deps through `.pth` + `addsitedir`, so files stay where they were
# declared rather than being materialised into the venv's site-packages.
import conflict
print(conflict.__file__)
assert "py_venv_conflict/a/" in conflict.__file__ or "py_venv_conflict/b/" in conflict.__file__

import noconflict
print(noconflict.__file__)
assert "py_venv_conflict/a/" in noconflict.__file__ or "py_venv_conflict/b/" in noconflict.__file__

import py_venv_conflict.lib as srclib
print(srclib.__file__)
# First-party `:lib` target's source file stays under the runfiles tree,
# not inside the venv — same before and after the refactor.
assert not srclib.__file__.startswith(sys.prefix)
