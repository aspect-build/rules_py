#!/usr/bin/env python3

"""
A quick and dirty script which implements include() on the MODULE.bazel.
"""

import re
import sys
from difflib import Differ
from pathlib import Path
from tempfile import mkdtemp
from subprocess import call
from shutil import rmtree

ANCHOR_RE = re.compile("""\
################################################################################
# Dev deps
((#.*?\n)+)\
""", re.MULTILINE)

INCLUDE_RE = re.compile(r"""# include\("(.*?)"\)""")

if __name__ == "__main__":
    # FIXME: Work properly under `bazel run`
    root = Path(__file__).parent.parent.parent

    with open(root / "MODULE.bazel", "r") as fp:
        module_content = fp.read()

    anchor_match = re.search(ANCHOR_RE, module_content)

    # Slice off the file to the end of the include header
    header = module_content[:anchor_match.end()]

    new_content_buffer = [header, "#"*80, "# Begin included content\n"]
    # The include config is group 1
    for match in re.finditer(INCLUDE_RE, anchor_match.group(1)):
        bazel_path = match.group(1)
        bazel_path = bazel_path.replace("//", "").replace(":", "/")
        with open(root / bazel_path, "r") as fp:
            new_content_buffer.append("#"*40)
            new_content_buffer.append("# from {}".format(bazel_path))
            new_content_buffer.append(fp.read())
            
    new_module_content = "\n".join(new_content_buffer)
    if new_module_content != module_content or "-f" in sys.argv:
        diff = Differ().compare(module_content.splitlines(), new_module_content.splitlines())
        print("\n".join(diff))

        with open(root / "MODULE.bazel", "w") as fp:
            fp.write(new_module_content)

        # Now the really cursed bit is that we need to generate an updated
        # patchfile if the MODULE changes, since the only way we can remove
        # content from the MODULE today is with patches.
        base = Path(mkdtemp())

        a = base / "a"
        a.mkdir()
        
        b = base / "b"
        b.mkdir()

        # B is our desired end state (stripped)
        # A is our current state     (included)
        with open(a / "MODULE.bazel", "w") as fp:
            fp.write(new_module_content)

        with open(b / "MODULE.bazel", "w") as fp:
            fp.write(module_content[:anchor_match.start()])

        with open(root / ".bcr/patches/remove_dev_deps.patch", "w") as fp:
            # Call diff and use it to directly write the new patchfile
            call(["diff", "-u", "a/MODULE.bazel", "b/MODULE.bazel"], cwd=base, stdout=fp,)

        # Clean up after ourselves
        rmtree(base)

        # And signal that change was made
        exit(1)
