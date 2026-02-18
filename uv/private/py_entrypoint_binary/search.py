#!/usr/bin/env python3

"""
Search installed packages for entrypoints and expand the entrypoint template.
"""

import argparse
import configparser
from pathlib import Path
import sys


class CaseSensitiveConfigParser(configparser.ConfigParser):
    optionxform = staticmethod(str)

# Quick and dirty re-implementation of the setuptools search.

PARSER = argparse.ArgumentParser()
PARSER.add_argument("--template")
PARSER.add_argument("--script")
opts, args = PARSER.parse_known_args()

print(repr(opts), file=sys.stderr)

entrypoint = None
for e in sys.path:
    if entrypoint:
        break
    
    print("{}:".format(e), file=sys.stderr)
    for entrypoints in Path(e).glob("*.dist-info/entry_points.txt"):        
        cp = CaseSensitiveConfigParser(delimiters=('=',))
        cp.read([entrypoints])

        if "console_scripts" in cp:
            for e in cp["console_scripts"]:
                print(entrypoints, e, cp["console_scripts"][e], file=sys.stderr)
                if e == opts.script:
                    entrypoint = cp["console_scripts"][e]
                    break

if not entrypoint:
    print("Failed to identify the requested entrpoint script!", file=sys.stderr)
    exit(1)

# <name> = <package_or_module>[:<object>[.<attr>[.<nested-attr>]*]]
package, symbol = entrypoint.split(":")

if "." in symbol:
    fn, tail = symbol.split(".", 1)
    alias = "{fn} = {fn}.{tail}\n".format(fn = fn, tail = tail)
else:
    fn = symbol
    tail = ""
    alias = ""
    
with open(opts.template, "r") as fp:
    template = fp.read()


print(template.format(
    package = package,
    fn = fn,
    alias = alias,
))
