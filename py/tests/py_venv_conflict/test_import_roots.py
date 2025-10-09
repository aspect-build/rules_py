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

import conflict
print(conflict.__file__)
assert conflict.__file__.startswith(sys.prefix)

import noconflict
print(noconflict.__file__)
assert noconflict.__file__.startswith(sys.prefix)

import py_venv_conflict.lib as srclib
print(srclib.__file__)
assert not srclib.__file__.startswith(sys.prefix)
