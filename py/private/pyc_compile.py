"""Compile PEP 552 bytecode or relocate it into sourceless legacy layout."""

import argparse
import py_compile
import sys

_PRERELEASE_ABBREVS = {"alpha": "a", "beta": "b", "candidate": "rc"}


parser = argparse.ArgumentParser()
parser.add_argument("--src")
parser.add_argument("--pycache")
parser.add_argument("--dfile")
parser.add_argument("--pyc")
parser.add_argument("--expect-version")
args = parser.parse_args()

if not (args.src and args.pycache and args.dfile and args.pyc):
    parser.error("compilation requires --src, --pycache, --dfile, and --pyc")

if args.expect_version:
    actual = "{}.{}.{}".format(*sys.version_info[:3])
    if sys.version_info.releaselevel != "final":
        actual += _PRERELEASE_ABBREVS.get(
            sys.version_info.releaselevel, sys.version_info.releaselevel
        ) + str(sys.version_info.serial)
    expected = args.expect_version
    # Bytecode magic is stable within a stable feature release but may change
    # between prereleases: full equality is required when either side is a
    # prerelease, otherwise major.minor must match.
    prerelease = (
        sys.version_info.releaselevel != "final"
        or not expected.replace(".", "").isdigit()
    )
    if actual.split(".")[:2] != expected.split(".")[:2] or (
        prerelease and actual != expected
    ):
        sys.exit(
            "pyc compiler is Python {}, expected {}: emitted bytecode would "
            "not match the target runtime".format(actual, expected)
        )

py_compile.compile(
    args.src,
    cfile=args.pycache,
    dfile=args.dfile,
    doraise=True,
    invalidation_mode=py_compile.PycInvalidationMode.UNCHECKED_HASH,
)
with open(args.pycache, "rb") as src, open(args.pyc, "wb") as dest:
    dest.write(src.read())
