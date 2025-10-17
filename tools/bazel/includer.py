#!/usr/bin/env python3

"""
A quick and dirty script which implements include() on the MODULE.bazel.
"""

import re
from difflib import Differ
from pathlib import Path

ANCHOR_RE = re.compile("""\
################################################################################
# Dev deps
((#.*?\n)+)\
""", re.MULTILINE)

INCLUDE_RE = re.compile("""\
# include\("(.*?)"\)
""")

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
    if new_module_content != module_content:
        diff = Differ().compare(module_content.splitlines(), new_module_content.splitlines())
        print("\n".join(diff))

        with open(root / "MODULE.bazel", "w") as fp:
            fp.write(new_module_content)
            exit(1)
