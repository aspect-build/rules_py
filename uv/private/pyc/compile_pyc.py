"""Pre-compile .py files to .pyc bytecode.

Usage: python compile_pyc.py <src_dir> <out_dir>

Copies src_dir to out_dir, then runs compileall over the copy.
Per-file syntax errors are non-fatal (some wheels vendor Python 2 code),
but a broken interpreter is fatal.
"""

import compileall
import py_compile
import shutil
import sys


def main():
    if len(sys.argv) != 3:
        print("Usage: compile_pyc.py <src_dir> <out_dir>", file=sys.stderr)
        sys.exit(1)

    src_dir, out_dir = sys.argv[1], sys.argv[2]

    shutil.copytree(src_dir, out_dir, symlinks=False, dirs_exist_ok=True)

    ok = compileall.compile_dir(
        out_dir,
        quiet=1,
        invalidation_mode=py_compile.PycInvalidationMode.UNCHECKED_HASH,
    )

    if not ok:
        # compileall returns False when some files failed to compile.
        # This is expected for wheels that vendor Python 2 syntax or
        # otherwise-broken .py files. We log but don't fail the build.
        print(
            "compile_pyc: some files in {} failed to compile (non-fatal)".format(out_dir),
            file=sys.stderr,
        )


if __name__ == "__main__":
    main()
